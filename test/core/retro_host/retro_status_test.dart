import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `status` as anyps5-retro-host docs/protocol.md "status" gives it. The base is the status the
/// host repository's play-and-quit fixture session sends; when ANYPS5_RETRO_HOST_CHECKOUT names a
/// checkout of that repository, the test also reads every status its fixture sessions send.
void main() {
  Map<String, Object?> status([Map<String, Object?> changes = const {}]) => {
    'ready': true,
    'ended': false,
    'error': '',
    'errorCode': '',
    'aspect': 1.3333333333333333,
    'hardware': false,
    'resolutionError': '',
    'graphicsPending': false,
    'progressLabel': null,
    'progressPercent': null,
    'options': <String, Object?>{},
    ...changes,
  };

  Map<String, Object?> discs(int count) => {
    'labels': [for (var i = 0; i < count; i++) 'Disc ${i + 1}'],
    'inserted': 0,
    'insertedDiscPath': 'a.cue',
    'playedDiscPath': '',
    'busy': false,
    'failed': false,
  };

  test('a status without cardUnreadable reads as a readable card', () {
    expect(RetroStatus.parse(status()).cardUnreadable, isFalse);
  });

  test('cardUnreadable is read when the host sends it', () {
    expect(RetroStatus.parse(status({'cardUnreadable': true})).cardUnreadable, isTrue);
    expect(RetroStatus.parse(status({'cardUnreadable': false})).cardUnreadable, isFalse);
  });

  test('a cardUnreadable that is not a boolean is a protocol error', () {
    expect(() => RetroStatus.parse(status({'cardUnreadable': 1})), throwsA(isA<RetroProtocolError>()));
    expect(() => RetroStatus.parse(status({'cardUnreadable': null})), throwsA(isA<RetroProtocolError>()));
  });

  test("a host's hostExited or hostHung is read as other", () {
    for (final code in [RetroErrorCode.hostExited, RetroErrorCode.hostHung]) {
      final read = RetroStatus.parse(status({'ended': true, 'error': 'x', 'errorCode': code}));
      expect(read.errorCode, RetroErrorCode.other, reason: code);
    }
  });

  test('every other errorCode, known or not, is kept as the host sent it', () {
    for (final code in ['', 'bios', 'disc', 'core', 'stalled', 'didNotStart', 'frameTooLarge', 'other', 'later']) {
      expect(RetroStatus.parse(status({'ended': code.isNotEmpty, 'errorCode': code})).errorCode, code);
    }
  });

  test('discs may list 128 discs and no more', () {
    expect(RetroStatus.parse(status({'discs': discs(128)})).discs!.labels, hasLength(128));
    expect(() => RetroStatus.parse(status({'discs': discs(129)})), throwsA(isA<RetroProtocolError>()));
  });

  test('a disc inserted past the 128th shows as none inserted', () {
    final read = RetroStatus.parse(
      status({
        'discs': {...discs(128), 'inserted': null},
      }),
    );
    expect(read.discs!.inserted, isNull);
  });

  test('every status in the host repository fixtures is read', () {
    final checkout = Platform.environment['ANYPS5_RETRO_HOST_CHECKOUT'];
    if (checkout == null || checkout.isEmpty) {
      markTestSkipped('ANYPS5_RETRO_HOST_CHECKOUT is not set');
      return;
    }
    var read = 0;
    for (final file in Directory(p.join(checkout, 'fixtures', 'v1', 'sessions')).listSync().whereType<File>()) {
      final session = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final steps = (session['steps']! as List).cast<Map<String, Object?>>();
      final statusCalls = <Object?>{};
      for (final step in steps) {
        final message = step['message'] as Map<String, Object?>?;
        if (message == null || step['invalid'] != null) continue;
        if (step['from'] == 'launcher' && message['type'] == 'call' && message['method'] == 'status') {
          statusCalls.add(message['id']);
        }
        if (step['from'] == 'host' && message['type'] == 'reply' && statusCalls.contains(message['id'])) {
          final result = message['result'];
          if (result is Map<String, Object?> && !RetroStatus.isFailureReport(result)) {
            RetroStatus.parse(result);
            read++;
          }
        }
      }
    }
    expect(read, greaterThan(0));
  });
}
