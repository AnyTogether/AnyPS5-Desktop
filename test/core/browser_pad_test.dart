import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/remote/browser_pad_access.dart';
import 'package:anyps5_desktop/core/remote/browser_pad_input.dart';
import 'package:anyps5_desktop/core/remote/remote_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('access', () {
    late DateTime now;
    late BrowserPadAccess access;
    setUp(() {
      now = DateTime.utc(2027, 1, 1);
      access = BrowserPadAccess(clock: () => now);
    });

    test('a token is good once and becomes a session', () {
      final token = access.currentToken();
      expect(token.value.length, greaterThanOrEqualTo(22));
      expect(access.currentToken(), token, reason: 'the QR code keeps its token while it is good');
      final session = access.redeem(token.value, deviceName: 'iPhone · Web')!;
      expect(session.deviceId, startsWith(BrowserPadAccess.devicePrefix));
      expect(session.key, isNull);
      expect(access.redeem(token.value, deviceName: 'iPhone · Web'), isNull, reason: 'a second phone gets nothing');
      expect(access.currentToken(), isNot(token));
    });

    test('a token expires', () {
      final token = access.currentToken();
      now = now.add(BrowserPadAccess.tokenLifetime + const Duration(seconds: 1));
      expect(access.redeem(token.value, deviceName: 'Phone'), isNull);
      expect(access.currentToken(), isNot(token));
    });

    test('a wrong or renewed token is refused', () {
      final token = access.currentToken();
      expect(access.redeem('${token.value}x', deviceName: 'Phone'), isNull);
      expect(access.redeem('', deviceName: 'Phone'), isNull);
      access.renewToken();
      expect(access.redeem(token.value, deviceName: 'Phone'), isNull);
    });

    test('the cookie is bound to the redeemed session', () {
      final session = access.redeem(access.currentToken().value, deviceName: 'Phone')!;
      final cookie = BrowserPadAccess.setCookie(session);
      expect(cookie, startsWith('${BrowserPadAccess.cookieName}=${session.id};'));
      expect(cookie, contains('HttpOnly'));
      expect(cookie, contains('SameSite=Strict'));
      expect(
        access.sessionForCookie('theme=dark; ${BrowserPadAccess.cookieName}=${session.id}')?.deviceId,
        session.deviceId,
      );
      expect(access.sessionForCookie('${BrowserPadAccess.cookieName}=${session.id}x'), isNull);
      expect(access.sessionForCookie(null), isNull);
      expect(access.sessionForCookie('other=${session.id}'), isNull);
    });

    test('an idle session ends but a connected one stays', () {
      final idle = access.redeem(access.currentToken().value, deviceName: 'A')!;
      final playing = access.redeem(access.currentToken().value, deviceName: 'B')!;
      access.setConnected(playing.id, true);
      now = now.add(BrowserPadAccess.sessionIdle + const Duration(seconds: 1));
      expect(access.expireIdle().map((session) => session.id), [idle.id]);
      expect(access.session(playing.id), isNotNull);
    });

    test('sessions are limited and the oldest idle one gives way', () {
      BrowserPadSession? first;
      for (var index = 0; index < BrowserPadAccess.maxSessions; index++) {
        final session = access.redeem(access.currentToken().value, deviceName: '$index')!;
        first ??= session;
        now = now.add(const Duration(seconds: 1));
      }
      expect(access.redeem(access.currentToken().value, deviceName: 'late'), isNotNull);
      expect(access.session(first!.id), isNull);
      for (final session in access.all) {
        access.setConnected(session.id, true);
      }
      expect(access.redeem(access.currentToken().value, deviceName: 'full'), isNull);
    });

    test('only this site is allowed', () {
      bool allowed(String? origin, String? host, {bool socket = true}) => BrowserPadAccess.allowed(
        origin: origin,
        host: host,
        serverHost: '192.168.1.20',
        port: 47710,
        requireOrigin: socket,
      );
      expect(allowed('http://192.168.1.20:47710', '192.168.1.20:47710'), isTrue);
      expect(allowed(null, '192.168.1.20:47710', socket: false), isTrue, reason: 'a plain page load has no Origin');
      expect(allowed(null, '192.168.1.20:47710'), isFalse, reason: 'a WebSocket without Origin');
      expect(allowed('http://evil.example', '192.168.1.20:47710'), isFalse);
      expect(allowed('https://192.168.1.20:47710', '192.168.1.20:47710'), isFalse);
      expect(allowed('http://192.168.1.20:47711', '192.168.1.20:47710'), isFalse);
      expect(allowed('null', '192.168.1.20:47710'), isFalse);
      expect(allowed('http://rebound.example:47710', 'rebound.example:47710'), isFalse, reason: 'DNS rebinding');
      expect(allowed(null, null, socket: false), isFalse);
    });

    test('only local peers are local', () {
      for (final address in [
        '192.168.0.4',
        '10.1.2.3',
        '172.16.0.1',
        '172.31.255.1',
        '169.254.3.3',
        '127.0.0.1',
        '::ffff:192.168.1.9',
        'fe80::1%en0',
        'fd12::4',
        '::1',
      ]) {
        expect(BrowserPadAccess.isLocal(address), isTrue, reason: address);
      }
      for (final address in ['8.8.8.8', '172.32.0.1', '100.64.1.1', '2001:db8::1', '::ffff:1.1.1.1', 'nonsense']) {
        expect(BrowserPadAccess.isLocal(address), isFalse, reason: address);
      }
    });

    test('device names from the user agent', () {
      expect(BrowserPadAccess.deviceName('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)'), 'iPhone · Web');
      expect(
        BrowserPadAccess.deviceName('Mozilla/5.0 (Linux; Android 15; Pixel 9) Chrome/130 Mobile'),
        'Android · Web',
      );
      expect(
        BrowserPadAccess.deviceName('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Mobile/15E148'),
        'iPad · Web',
      );
      expect(BrowserPadAccess.deviceName(null), 'Phone · Web');
    });

    test('the rate limiter refills', () {
      final limiter = RateLimiter(capacity: 3, perSecond: 1, clock: () => now);
      expect([for (var i = 0; i < 4; i++) limiter.allow('a')], [true, true, true, false]);
      expect(limiter.allow('b'), isTrue, reason: 'another peer has its own bucket');
      now = now.add(const Duration(seconds: 1));
      expect(limiter.allow('a'), isTrue);
      expect(limiter.allow('a'), isFalse);
    });
  });

  group('input', () {
    BrowserPadState? pad(String text) => switch (BrowserPadMessage.parse(text)) {
      BrowserPadInput(:final state) => state,
      _ => null,
    };

    test('a pad message becomes the pad state', () {
      final state = pad('{"t":"pad","b":${PadBits.cross | PadBits.up | PadBits.l1},"s":[0,255,128,64],"l2":0,"r2":0}')!;
      expect(state.buttons, PadBits.cross | PadBits.up | PadBits.l1);
      expect(state.sticks, [0, 255, 128, 64]);
      expect((state.l2, state.r2), (0, 0));
      expect(state.touches, isEmpty);
    });

    test('values are clamped and foreign bits dropped', () {
      final state = pad('{"t":"pad","b":${0xFFFFFFFF},"s":[-40,999,127.6,12],"l2":300,"r2":-3}')!;
      expect(state.buttons, BrowserPadMessage.buttonMask);
      expect(state.sticks, [0, 255, 128, 12]);
      expect(state.l2, 255);
      expect(state.r2, 255, reason: "R2's button held is a full pull");
    });

    test('triggers and their buttons agree', () {
      final pulled = pad('{"t":"pad","b":0,"l2":90}')!;
      expect(pulled.buttons, PadBits.l2);
      expect(pulled.l2, 90);
      expect(pulled.sticks, [128, 128, 128, 128], reason: 'sticks left out are centred');
      expect(pad('{"t":"pad","b":${PadBits.r2}}')!.r2, 255);
    });

    test('touchpad fingers', () {
      final state = pad('{"t":"pad","b":${PadBits.touchPad},"tp":[[3,100,2000],[4,5000,-1],[5,1,1]]}')!;
      expect(state.touches, [(3, 100, 1079), (4, 1919, 0)]);
      final packet = state.packet(sequence: 1, sentMicros: 2, session: 3);
      final data = ByteData.sublistView(packet);
      expect([packet[44], packet[45]], [1, 3]);
      expect(data.getUint16(46, Endian.little), 100);
      expect(data.getUint16(48, Endian.little), 1079);
      expect([packet[50], packet[51]], [1, 4]);
    });

    test("the pad state is the engine's packet", () {
      final state = pad('{"t":"pad","b":${PadBits.options},"s":[1,2,3,4],"l2":5,"r2":6}')!;
      final session = BigInt.parse('DEADBEEF01020304', radix: 16).toSigned(64).toInt();
      final packet = state.packet(sequence: 7, sentMicros: 8, session: session);
      expect(RemotePacket.inputSession(packet), session);
      final data = ByteData.sublistView(packet);
      expect(data.getUint32(32, Endian.little), PadBits.options | PadBits.l2 | PadBits.r2);
      expect(packet.sublist(36, 42), [1, 2, 3, 4, 5, 6]);
      expect(data.getFloat32(60, Endian.little), closeTo(9.80665, 1e-4));
    });

    test('other messages', () {
      expect(
        BrowserPadMessage.parse('{"t":"btn","n":"ps"}'),
        isA<BrowserPadButton>().having((m) => m.name, 'name', 'ps'),
      );
      expect(BrowserPadMessage.parse('{"t":"btn","n":"create"}'), isA<BrowserPadButton>());
      expect(BrowserPadMessage.parse('{"t":"btn","n":"launch"}'), isNull);
      expect(BrowserPadMessage.parse('{"t":"ping","at":12.5}'), isA<BrowserPadPing>().having((m) => m.at, 'at', 12.5));
      expect(BrowserPadMessage.parse('{"t":"lat","ms":14}'), isA<BrowserPadLatency>());
      expect(BrowserPadMessage.parse('{"t":"lat","ms":-1}'), isNull);
    });

    test('broken messages are dropped', () {
      for (final text in [
        '',
        'nope',
        '[]',
        '{"t":"pad"}',
        '{"t":"pad","b":"1"}',
        '{"t":"pad","b":true}',
        '{"t":"pad","b":1,"s":[1,2,3]}',
        '{"t":"pad","b":1,"s":[1,2,3,"x"]}',
        '{"t":"what"}',
        '{"b":1}',
        '{"t":"pad","b":-1}',
        '{"t":"pad","b":1,"pad":"${'x' * 5000}"}',
      ]) {
        expect(BrowserPadMessage.parse(text), isNull, reason: text);
      }
    });

    test("the game's output for the page", () {
      final bytes = Uint8List(RemotePacket.outputSize);
      ByteData.sublistView(bytes)
        ..setUint32(0, RemotePacket.outputMagic, Endian.little)
        ..setUint16(4, 1, Endian.little)
        ..setUint16(6, RemotePacket.outputSize, Endian.little);
      bytes[24] = 200;
      bytes[25] = 30;
      expect(BrowserPadReply.output(bytes), '{"big":200,"small":30,"t":"out"}');
      bytes
        ..[26] = 1
        ..[27] = 0x10
        ..[28] = 0x80
        ..[29] = 0xFF;
      expect(BrowserPadReply.output(bytes), '{"big":200,"rgb":"#1080ff","small":30,"t":"out"}');
      expect(BrowserPadReply.output(bytes.sublist(0, 20)), isNull);
    });
  });

  test("the page is the macOS launcher's and speaks the server's protocol", () {
    final page = File('assets/browser_pad/index.html').readAsStringSync();
    expect(page, contains('<meta name="anyps5-browser-pad" content="1">'));
    for (final sent in ['t: "pad"', 't: "btn"', 't: "ping"', 't: "lat"']) {
      expect(page, contains(sent));
    }
    for (final heard in ['wait', 'pairing', 'busy', 'welcome', 'rejected', 'out', 'player', 'look', 'pong']) {
      expect(page, contains('case "$heard"'));
    }
    expect(page, isNot(contains('https://')), reason: 'no outside requests');
    // With ANYPS5_ARM set to an AnyPS5-ARM checkout, the copy must be its file (tool/sync_browser_pad.sh).
    final arm = Platform.environment['ANYPS5_ARM'];
    final mac = File('${arm ?? ''}/tools/macos/launcher/BrowserPad/index.html');
    if (arm != null) {
      expect(page, mac.readAsStringSync(), reason: 'run tool/sync_browser_pad.sh');
    }
  });

  test('turned to landscape, the page goes full screen with the next finished touch', () {
    final page = File('assets/browser_pad/index.html').readAsStringSync();
    // A browser takes full screen from pointerup on a touch screen, never from pointerdown.
    expect(page, contains('stage.addEventListener("pointerup", fullscreenOnTouch)'));
    final down = page.substring(page.indexOf('function down(event)'), page.indexOf('function move(event)'));
    expect(down, isNot(contains('ullscreen')), reason: 'pointerdown gives no user activation on a touch screen');
    // Wanted again each time the phone turns to landscape, and again after a refusal.
    expect(page, contains('matchMedia("(orientation: landscape)")'));
    expect(page, contains('goFullscreen().catch(() => { fullscreenWanted = true; })'));
    expect(page, isNot(contains('Android/i.test')), reason: 'any browser that has the Fullscreen API');
  });
}
