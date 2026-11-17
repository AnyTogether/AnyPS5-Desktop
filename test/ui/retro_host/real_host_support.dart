import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:anyps5_desktop/core/retro_host/frame_ring.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_session.dart';
import 'package:flutter_test/flutter_test.dart';

// What the tests against the real emulator host share (ANYPS5_RETRO_HOST_REAL).

/// Waits until [done] (true or a future of true), checking every 50 ms.
Future<void> until(FutureOr<bool> Function() done, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) fail('not done within $limit');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<Uint8List?> framePixels(ui.Image? image) async {
  if (image == null) return null;
  final clone = image.clone();
  try {
    final data = await clone.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data?.buffer.asUint8List();
  } finally {
    clone.dispose();
  }
}

bool showsPicture(Uint8List pixels) {
  for (var i = 0; i < pixels.length; i += 4) {
    if (pixels[i] != 0 || pixels[i + 1] != 0 || pixels[i + 2] != 0) return true;
  }
  return false;
}

bool samePixels(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String pythonPath() {
  final name = Platform.isWindows ? 'python' : 'python3';
  final found = Process.runSync(Platform.isWindows ? 'where' : 'which', [name]);
  final path = (found.stdout as String)
      .split(RegExp(r'\r?\n'))
      .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
  if (path.isEmpty) throw StateError('$name is not on PATH');
  return path.trim();
}

/// The real client, with the answer to every call the launcher made through it.
class RecordingSession implements RetroHostSession {
  RecordingSession(this.client);

  final RetroHostClient client;

  /// Each call's method, argument and result, in the order the results came.
  final answers = <(String, Object?, Object?)>[];

  @override
  Future<Object?> call(String method, [Object? args]) async {
    final result = await client.call(method, args);
    answers.add((method, args, result));
    return result;
  }

  @override
  Stream<RetroFrameEvent> get frames => client.frames;
  @override
  PinnedFrame? get frame => client.frame;
  @override
  Future<void> get ready => client.ready;
  @override
  Future<RetroHostEnd> get ended => client.ended;
  @override
  Stream<RetroRumble> get rumble => client.rumble;
  @override
  set inputFocus(bool focused) => client.inputFocus = focused;
  @override
  Future<int> startGame(Map<String, Object?> args) => client.startGame(args);
  @override
  Future<RetroStatus?> status() => client.status();
  @override
  Future<RetroStatus?> stopGame() => client.stopGame();
  @override
  void input(int port, int buttons, {int leftX = 0, int leftY = 0, int rightX = 0, int rightY = 0}) =>
      client.input(port, buttons, leftX: leftX, leftY: leftY, rightX: rightX, rightY: rightY);
  @override
  void shutdown() => client.shutdown();
  @override
  Future<void> close() => client.close();
}
