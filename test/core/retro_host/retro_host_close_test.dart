import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A program that exits at once without answering `hello`, so the client ends the connection.
List<String> _exitsAtOnce() => Platform.isWindows
    ? [p.join(Platform.environment['SystemRoot'] ?? r'C:\Windows', 'System32', 'cmd.exe'), '/c', 'exit 0']
    : ['/bin/sh', '-c', 'exit 0'];

void main() {
  test('a focus change after close is ignored', () async {
    final client = RetroHostClient.start(command: _exitsAtOnce());
    unawaited(client.ready.then((_) {}, onError: (_) {}));
    await client.ended.timeout(const Duration(seconds: 20));
    await client.close();
    client.inputFocus = false;
    client.inputFocus = true;
  });
}
