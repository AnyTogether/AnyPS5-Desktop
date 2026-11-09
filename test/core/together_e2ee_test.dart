import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/together/account.dart';
import 'package:anyps5_desktop/core/together/e2ee.dart';
import 'package:anyps5_desktop/core/together/e2ee_client.dart';
import 'package:anyps5_desktop/core/together/e2ee_keys.dart';
import 'package:anyps5_desktop/core/together/messages.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:anyps5_desktop/core/together/token_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_e2ee.dart';
import '../support/fake_together.dart';

/// End-to-end encrypted direct messages as the launcher sends and reads them, against the fake
/// server's E2EE routes (AnyTogether's docs/e2ee.md, "What every client does"): the device keys
/// made once and registered, every message sealed for exactly both people's devices (sealed
/// again when they changed), plain only where the other person has no device yet, the lock,
/// the safety number and the devices-changed notice, sealed photos, edits, reports, and a server
/// without any of it.
void main() {
  late FakeTogether server;
  late FakeE2ee e2eeServer;
  late TogetherAccount account;
  late TogetherSocket socket;
  late EndToEnd e2ee;
  late Messages messages;
  late MemoryE2eeKeyStore keys;
  late MemoryE2eeNotesStore notes;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 500 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  Future<void> signIn() async {
    await account.startEmail('utku@example.com');
    await account.verifyEmail('123456');
    socket.start();
    await until(() => server.sockets.isNotEmpty);
  }

  setUp(() async {
    server = await FakeTogether.start();
    e2eeServer = FakeE2ee(server);
    server.friend('u-ana', 'ana', 'Ana');
    server.conversation('c-ana', [FakeTogether.card('u-ana', 'ana', 'Ana')]);
    account = TogetherAccount(base: server.base, store: MemoryTokenStore(), clientName: 'launcher-linux/test');
    socket = TogetherSocket(account: account);
    keys = MemoryE2eeKeyStore();
    notes = MemoryE2eeNotesStore();
    e2ee = EndToEnd(account: account, keys: () => keys, notes: () => notes, deviceName: () => 'Desk');
    messages = Messages(account: account, socket: socket, e2ee: e2ee);
  });

  tearDown(() async {
    messages.dispose();
    socket.dispose();
    account.close();
    await server.close();
  });

  Future<DeviceSecrets> anaWithDevice() => e2eeServer.addDevice('u-ana', name: 'Ana’s phone');

  /// What Ana's device reads of the last message in the conversation.
  Future<Opened> anaOpens(DeviceSecrets ana, Map<String, dynamic> message) => open(
    SealedMessage.fromJson(message['sealed'])!,
    conversationId: message['conversationId'] as String,
    messageId: message['id'] as String,
    authorId: message['authorId'] as String,
    me: ana,
    authorDevices: [for (final d in e2eeServer.devices['u-me']!) PublicDevice.fromJson(d)!],
  );

  /// Ana's device seals [text] for every active device of both people.
  Future<SealedMessage> anaSeals(DeviceSecrets ana, String messageId, String text, {List<PublicDevice>? to}) async =>
      (await seal(
        conversationId: 'c-ana',
        messageId: messageId,
        senderUserId: 'u-ana',
        sender: ana,
        recipients:
            to ??
            [
              for (final d in [...e2eeServer.devices['u-me']!, ...e2eeServer.devices['u-ana']!])
                PublicDevice.fromJson(d)!,
            ],
        payload: E2eePayload(text: text),
      )).sealed;

  group('this device', () {
    test('makes its keys once, keeps them, and registers them signed for the user', () async {
      await signIn();
      expect(await e2ee.start(), isTrue);
      final kept = keys.kept['u-me']!;
      expect(e2eeServer.session!['id'], kept.deviceId);
      expect(e2eeServer.session!['name'], 'Desk');
      expect(server.callsTo('me/e2ee/device', method: 'PUT'), hasLength(1));

      // Signed in again on this device: the same keys, already registered, so no PUT.
      e2ee.clear();
      expect(await e2ee.start(), isTrue);
      expect(e2ee.device!.deviceId, kept.deviceId);
      expect(server.callsTo('me/e2ee/device', method: 'PUT'), hasLength(1));

      // Registered by an older launcher under the computer's own name: registered again under
      // this one's, the same keys.
      e2eeServer.session!['name'] = 'DESKTOP-7Q2';
      e2ee.clear();
      expect(await e2ee.start(), isTrue);
      expect(server.callsTo('me/e2ee/device', method: 'PUT'), hasLength(2));
      expect(e2eeServer.session!['name'], 'Desk');
      expect(e2eeServer.session!['id'], kept.deviceId);
    });

    test('another account on the same profile gets keys of its own', () async {
      await signIn();
      await e2ee.start();
      final first = keys.kept['u-me']!.deviceId;
      await account.signOut();
      server.me = {'id': 'u-two', 'handle': 'two', 'displayName': 'Two'};
      await signIn();
      await e2ee.start();
      expect(keys.kept['u-two']!.deviceId, isNot(first));
    });

    test('on a server without end-to-end encryption, every message stays plain', () async {
      server.handlers.clear();
      await signIn();
      expect(await e2ee.start(), isFalse);
      expect(e2ee.available, isFalse);
      await messages.refresh();
      await messages.show('c-ana');
      expect(messages.lockOf('c-ana'), isNull);
      await messages.send('Hi Ana');
      await until(() => server.threads['c-ana']!.length == 1);
      expect(server.threads['c-ana']!.single['text'], 'Hi Ana');
      expect(messages.thread.single.text, 'Hi Ana');
    });
  });

  group('a direct conversation', () {
    setUp(signIn);

    test('with someone without a device key: plain, and said so', () async {
      await messages.refresh();
      await messages.show('c-ana');
      await until(() => messages.lockOf('c-ana') != null);
      expect(messages.lockOf('c-ana')!.state, EncryptionState.off);
      await messages.send('Plain for now');
      await until(() => server.threads['c-ana']!.length == 1);
      expect(server.threads['c-ana']!.single['text'], 'Plain for now');
      expect(server.threads['c-ana']!.single['sealed'], isNull);
    });

    test('with both people on a device: every message sealed for exactly their devices', () async {
      final ana = await anaWithDevice();
      await e2eeServer.addDevice('u-me', name: 'Utku’s phone');
      await messages.refresh();
      await messages.show('c-ana');
      await until(() => messages.lockOf('c-ana')?.state == EncryptionState.on);
      await messages.send('Merhaba Ana 👋', replyTo: null);
      await until(() => server.threads['c-ana']!.length == 1);
      final sent = server.threads['c-ana']!.single;
      expect(sent['text'], '[encrypted message]', reason: 'no plain text went to the server');
      final call = server.callsTo('conversations/c-ana/messages', method: 'POST').single;
      expect(call.body.containsKey('text'), isFalse);
      expect((call.body['sealed'] as Map)['keys'], hasLength(3));
      expect((await anaOpens(ana, sent)).payload.text, 'Merhaba Ana 👋');
      await until(() => messages.thread.single.seq == 1);
      expect(messages.thread.single.seal, SealState.opened);
      expect(messages.thread.single.text, 'Merhaba Ana 👋');
      expect(messages.conversations.single.encrypted, isTrue);
    });

    test('is sealed again when the server says the devices changed, and shows the change', () async {
      final ana = await anaWithDevice();
      await messages.refresh();
      await messages.show('c-ana');
      await until(() => messages.lockOf('c-ana')?.state == EncryptionState.on);
      expect(messages.lockOf('c-ana')!.notice, isNull, reason: 'the first time it only remembers');
      // Ana signs in on a laptop the launcher has not heard of yet.
      final laptop = await e2eeServer.addDevice('u-ana', name: 'Ana’s laptop');
      await messages.send('Still there?');
      await until(() => server.threads['c-ana']!.length == 1);
      expect(server.callsTo('conversations/c-ana/messages', method: 'POST'), hasLength(2));
      final sent = server.threads['c-ana']!.single;
      expect((sent['sealed'] as Map)['keys'], contains(laptop.deviceId));
      expect((await anaOpens(ana, sent)).payload.text, 'Still there?');
      expect((await anaOpens(laptop, sent)).payload.text, 'Still there?');
      expect(messages.lockOf('c-ana')!.notice, DevicesChange.theirs);
    });

    test('gives up after a few refusals, and the message says it did not get there', () async {
      await anaWithDevice();
      await messages.refresh();
      await messages.show('c-ana');
      await until(() => messages.lockOf('c-ana')?.state == EncryptionState.on);
      server.answers['POST conversations/c-ana/messages'] = (
        409,
        {'type': 'about:blank', 'status': 409, 'code': 'e2ee_devices', 'title': 'e2ee_devices'},
      );
      Object? failed;
      messages.onSendFailed = (error) => failed = error;
      await messages.send('Will not go');
      await until(() => messages.thread.single.failed);
      expect(server.callsTo('conversations/c-ana/messages', method: 'POST'), hasLength(Messages.sealTries));
      expect((failed as TogetherProblem).code, 'e2ee_devices');
    });

    test('never sends plain text where it saw encryption, and says why', () async {
      server.conversations['c-ana']!['encrypted'] = true;
      await messages.refresh();
      await messages.show('c-ana');
      await until(() => messages.lockOf('c-ana') != null);
      expect(messages.lockOf('c-ana')!.state, EncryptionState.noDevice);
      Object? failed;
      messages.onSendFailed = (error) => failed = error;
      await messages.send('Nobody can read this');
      await until(() => messages.thread.single.failed);
      expect(failed, isA<E2eeUnavailable>());
      expect(server.callsTo('conversations/c-ana/messages', method: 'POST'), isEmpty);
    });

    test('a plain message refused with e2ee_required is sealed instead', () async {
      await messages.refresh();
      await messages.show('c-ana');
      await until(() => messages.lockOf('c-ana')?.state == EncryptionState.off);
      // Ana's new app registers after the lock was worked out.
      final ana = await anaWithDevice();
      await messages.send('Sealed after all');
      await until(() => server.threads['c-ana']!.length == 1);
      expect((await anaOpens(ana, server.threads['c-ana']!.single)).payload.text, 'Sealed after all');
      expect(e2ee.sawEncrypted('c-ana'), isTrue);
    });

    test('opens what comes in, and says when it cannot', () async {
      final ana = await anaWithDevice();
      await messages.refresh();
      await messages.show('c-ana');
      await until(() => messages.lockOf('c-ana')?.state == EncryptionState.on);
      e2eeServer.receive('c-ana', 'u-ana', await anaSeals(ana, 'm-1', 'Hello from Ana'), id: 'm-1');
      await until(() => messages.thread.length == 1);
      expect(messages.thread.single.text, 'Hello from Ana');
      expect(messages.conversations.single.lastMessage!.text, 'Hello from Ana');

      // Sealed only for Ana's own device: sent before this one was added.
      final onlyAna = [for (final d in e2eeServer.devices['u-ana']!) PublicDevice.fromJson(d)!];
      e2eeServer.receive('c-ana', 'u-ana', await anaSeals(ana, 'm-2', 'Old', to: onlyAna), id: 'm-2');
      await until(() => messages.thread.length == 2);
      expect(messages.thread.last.seal, SealState.beforeDevice);
      expect(messages.thread.last.text, isNull);

      // Changed on the way: not shown.
      final good = await anaSeals(ana, 'm-3', 'Changed');
      final body = fromBase64(good.body)..[0] ^= 1;
      final changed = SealedMessage(
        device: good.device,
        eph: good.eph,
        nonce: good.nonce,
        body: toBase64(body),
        sig: good.sig,
        keys: good.keys,
      );
      e2eeServer.receive('c-ana', 'u-ana', changed, id: 'm-3');
      await until(() => messages.thread.length == 3);
      expect(messages.thread.last.seal, SealState.undecryptable);
      expect(messages.thread.last.text, isNull);

      // Signed by Ana's device but claimed to be the user's own: refused.
      final forged = await seal(
        conversationId: 'c-ana',
        messageId: 'm-4',
        senderUserId: 'u-me',
        sender: ana,
        recipients: [
          for (final d in [...e2eeServer.devices['u-me']!, ...e2eeServer.devices['u-ana']!]) PublicDevice.fromJson(d)!,
        ],
        payload: const E2eePayload(text: 'Not mine'),
      );
      e2eeServer.receive('c-ana', 'u-me', forged.sealed, id: 'm-4');
      await until(() => messages.thread.length == 4);
      expect(messages.thread.last.seal, SealState.undecryptable);
    });

    test('the list opens the last message for its preview', () async {
      final ana = await anaWithDevice();
      await e2ee.start();
      final sealed = await anaSeals(ana, 'm-1', 'Preview me');
      final message = e2eeServer.sealedMessage('c-ana', 1, 'u-ana', sealed, id: 'm-1');
      server.threads['c-ana']!.add(message);
      server.conversations['c-ana']!
        ..['lastSeq'] = 1
        ..['lastMessage'] = message
        ..['encrypted'] = true;
      await messages.refresh();
      expect(messages.conversations.single.lastMessage!.text, 'Preview me');
      expect(messages.conversations.single.encrypted, isTrue);
    });

    test('an edit is a new seal of the same message, its words only for the devices', () async {
      final ana = await anaWithDevice();
      await messages.refresh();
      await messages.show('c-ana');
      await until(() => messages.lockOf('c-ana')?.state == EncryptionState.on);
      await messages.send('Typo hree');
      await until(() => messages.thread.single.seq == 1);
      await messages.edit(messages.thread.single, 'Typo here');
      final edited = server.threads['c-ana']!.single;
      final call = server.callsTo('conversations/c-ana/messages/1', method: 'PATCH').single;
      expect(call.body.keys, ['sealed']);
      expect((await anaOpens(ana, edited)).payload.text, 'Typo here');
      expect(messages.thread.single.text, 'Typo here');
      expect(messages.thread.single.edited, isTrue);
    });

    test('a report sends the content key, which opens exactly that message', () async {
      final ana = await anaWithDevice();
      await messages.refresh();
      await messages.show('c-ana');
      await until(() => messages.lockOf('c-ana')?.state == EncryptionState.on);
      e2eeServer.receive('c-ana', 'u-ana', await anaSeals(ana, 'm-1', 'Something nasty'), id: 'm-1');
      await until(() => messages.thread.length == 1);
      await messages.report(messages.thread.single, 'harassment');
      final report = e2eeServer.reports.single;
      expect(report['targetKind'], 'message');
      expect(report['targetId'], 'm-1');
      expect(report['reason'], 'harassment');
      // As the server does with it: decrypt the stored body, check Ana's signature.
      final stored = server.threads['c-ana']!.single;
      final payload = await openWithKey(
        SealedMessage.fromJson(stored['sealed'])!,
        conversationId: 'c-ana',
        messageId: 'm-1',
        senderUserId: 'u-ana',
        contentKey: fromBase64(report['contentKey'], 32),
        authorSignKey: e2eeServer.devices['u-ana']!.single['signKey'] as String,
      );
      expect(payload.text, 'Something nasty');
    });

    test('a photo is sealed before it goes up, and opens from its link', () async {
      final ana = await anaWithDevice();
      await messages.refresh();
      await messages.show('c-ana');
      await until(() => messages.lockOf('c-ana')?.state == EncryptionState.on);
      final photo = Uint8List.fromList(List<int>.generate(5000, (i) => i * 7 % 256));
      await messages.sendMedia(
        'c-ana',
        kind: 'image',
        plain: () async => fail('a sealed conversation never uploads in the clear'),
        sealed: () => messages.e2ee!.uploadSealed(file: photo, kind: 'image', type: 'image/png', width: 64, height: 48),
      );
      await until(() => server.threads['c-ana']!.length == 1);
      final uploaded = e2eeServer.media.values.single;
      expect(uploaded.length, photo.length + 16);
      expect(_contains(uploaded, photo.sublist(0, 32)), isFalse, reason: 'only ciphertext went up');
      final opened = await anaOpens(ana, server.threads['c-ana']!.single);
      final attachment = opened.payload.attachment!;
      expect([attachment.kind, attachment.type, attachment.width, attachment.height], ['image', 'image/png', 64, 48]);
      expect(await openFile(uploaded, FilePart.file, attachment.key, attachment.nonce), photo);
      await until(() => messages.thread.single.seq == 1);
      final shown = messages.thread.single;
      expect(shown.attachment!.mediaId, shown.media!.id);
      expect(await messages.attachmentBytes(shown), photo);
    });

    test('a sealed attachment that names other media than the message is not shown', () async {
      final ana = await anaWithDevice();
      await messages.refresh();
      await messages.show('c-ana');
      await until(() => messages.lockOf('c-ana')?.state == EncryptionState.on);
      final sealed = (await seal(
        conversationId: 'c-ana',
        messageId: 'm-1',
        senderUserId: 'u-ana',
        sender: ana,
        recipients: [
          for (final d in [...e2eeServer.devices['u-me']!, ...e2eeServer.devices['u-ana']!]) PublicDevice.fromJson(d)!,
        ],
        payload: const E2eePayload(
          attachment: SealedAttachment(
            mediaId: 'other',
            kind: 'image',
            type: 'image/png',
            size: 1,
            key: 'k',
            nonce: 'n',
          ),
        ),
      )).sealed;
      e2eeServer.media['listed'] = [1];
      final message = e2eeServer.sealedMessage('c-ana', 1, 'u-ana', sealed, id: 'm-1', mediaId: 'listed');
      server.threads['c-ana']!.add(message);
      server.push('message.created', message);
      await until(() => messages.thread.length == 1);
      expect(messages.thread.single.seal, SealState.undecryptable);
    });
  });

  group('the safety number and the notice', () {
    setUp(signIn);

    test('the same number as the other side works out; compared until it changes', () async {
      await anaWithDevice();
      await messages.refresh();
      await messages.show('c-ana');
      await until(() => messages.lockOf('c-ana')?.state == EncryptionState.on);
      final lock = messages.lockOf('c-ana')!;
      final expected = await safetyNumber(
        'u-ana',
        [for (final d in e2eeServer.devices['u-ana']!) d['signKey'] as String],
        'u-me',
        [for (final d in e2eeServer.devices['u-me']!) d['signKey'] as String],
      );
      expect(lock.safetyNumber, expected);
      expect(lock.compared, isFalse);
      e2ee.markCompared('c-ana');
      expect(messages.lockOf('c-ana')!.compared, isTrue);
      expect(notes.kept['u-me']!['conversations']['c-ana']['compared'], expected);

      // Ana adds a device: the gateway says so; the number changes, the mark goes, a notice comes.
      await e2eeServer.addDevice('u-ana', name: 'Ana’s laptop');
      server.push('e2ee.devices', {'userId': 'u-ana'});
      await until(() => messages.lockOf('c-ana')?.notice == DevicesChange.theirs);
      expect(messages.lockOf('c-ana')!.compared, isFalse);
      expect(messages.lockOf('c-ana')!.safetyNumber, isNot(expected));
      expect(messages.lockOf('c-ana')!.theirs.active, hasLength(2));
      e2ee.dismissNotice('c-ana');
      expect(messages.lockOf('c-ana')!.notice, isNull);
      await messages.checkLock(messages.byId('c-ana')!, fresh: true);
      expect(messages.lockOf('c-ana')!.notice, isNull, reason: 'dismissed stays dismissed');
    });

    test('a device whose signature does not hold is left out', () async {
      await anaWithDevice();
      final stranger = await DeviceSecrets.generate();
      // Signed for someone else: it does not belong to Ana.
      final forged = await publicDevice(stranger, 'u-mallory');
      e2eeServer.devices['u-ana']!.add({
        'id': forged.id,
        'signKey': forged.signKey,
        'boxKey': forged.boxKey,
        'sig': forged.sig,
        'name': 'Not Ana',
        'createdAt': '2026-11-06T00:00:00Z',
        'removedAt': null,
      });
      await messages.refresh();
      await messages.show('c-ana');
      await until(() => messages.lockOf('c-ana')?.state == EncryptionState.on);
      expect(messages.lockOf('c-ana')!.theirs.active.map((d) => d.name), ['Ana’s phone']);
    });

    test('the user\'s own devices changing is a notice too', () async {
      await anaWithDevice();
      await messages.refresh();
      await messages.show('c-ana');
      await until(() => messages.lockOf('c-ana')?.state == EncryptionState.on);
      await e2eeServer.addDevice('u-me', name: 'Utku’s phone');
      server.push('e2ee.devices', {'userId': 'u-me'});
      await until(() => messages.lockOf('c-ana')?.notice == DevicesChange.mine);
    });
  });

  group('where the keys are kept', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('e2ee-keys'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('a file per user that only this user can read', () async {
      final store = FileE2eeKeyStore(p.join(temp.path, 'e2ee'));
      final secrets = await DeviceSecrets.generate();
      await store.save('u-me', secrets);
      expect((await store.load('u-me'))!.deviceId, secrets.deviceId);
      expect(await store.load('u-other'), isNull);
      if (!Platform.isWindows) {
        expect(File(store.fileOf('u-me')).statSync().mode & 0x1FF, 384); // 0600
        expect(Directory(store.folder).statSync().mode & 0x1FF, 448); // 0700
      }
    });

    test('a sealed file holds no secret in the clear, and one that does not open is no key', () async {
      final store = FileE2eeKeyStore(temp.path, sealer: _XorSealer());
      final secrets = await DeviceSecrets.generate();
      await store.save('u-me', secrets);
      expect(store.kind, 'dpapi');
      final raw = utf8.decode(File(store.fileOf('u-me')).readAsBytesSync(), allowMalformed: true);
      expect(raw, isNot(contains(toBase64(secrets.signSeed))));
      expect((await store.load('u-me'))!.deviceId, secrets.deviceId);
      expect(await FileE2eeKeyStore(temp.path, sealer: _XorSealer(refuse: true)).load('u-me'), isNull);
    });

    test('the Secret Service through secret-tool, one item per user, a file when it does not answer', () async {
      if (Platform.isWindows) return;
      final keyring = p.join(temp.path, 'keyring');
      Directory(keyring).createSync();
      final tool = p.join(temp.path, 'secret-tool');
      File(tool).writeAsStringSync('''#!/bin/sh
cmd="\$1"; shift
key=""
for a in "\$@"; do case "\$a" in --label=*) ;; *) key="\${key}_\$a" ;; esac; done
case "\$cmd" in
  store) cat > "$keyring/\$key" ;;
  lookup) [ -f "$keyring/\$key" ] && cat "$keyring/\$key" || exit 1 ;;
esac
''');
      Process.runSync('chmod', ['+x', tool]);
      final fallback = FileE2eeKeyStore(p.join(temp.path, 'fallback'));
      final store = SecretServiceE2eeKeyStore(fallback: fallback, tool: tool);
      final mine = await DeviceSecrets.generate();
      final theirs = await DeviceSecrets.generate();
      await store.save('u-me', mine);
      await store.save('u-two', theirs);
      expect(store.kind, 'secret-service');
      expect(File(fallback.fileOf('u-me')).existsSync(), isFalse);
      expect((await store.load('u-me'))!.deviceId, mine.deviceId);
      expect((await store.load('u-two'))!.deviceId, theirs.deviceId);

      final missing = SecretServiceE2eeKeyStore(fallback: fallback, tool: p.join(temp.path, 'no-such-tool'));
      await missing.save('u-me', mine);
      expect(missing.kind, 'file');
      expect((await missing.load('u-me'))!.deviceId, mine.deviceId);
    });
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var all = true;
    for (var j = 0; j < needle.length && all; j++) {
      all = haystack[i + j] == needle[j];
    }
    if (all) return true;
  }
  return false;
}

class _XorSealer implements Sealer {
  _XorSealer({this.refuse = false});

  final bool refuse;

  @override
  List<int> seal(List<int> data) => [for (final byte in data) byte ^ 0x5A];

  @override
  List<int>? open(List<int> data) => refuse ? null : [for (final byte in data) byte ^ 0x5A];
}
