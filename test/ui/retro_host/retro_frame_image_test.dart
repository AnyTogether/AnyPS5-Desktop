import 'dart:ui' as ui;

import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_frame_image.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_retro_host_session.dart';

Future<List<int>> _rgba(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List().toList();
}

Future<void> _shown(RetroFrameImage picture, int count) async {
  for (var i = 0; i < 200 && picture.shown < count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(picture.shown, count);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeFrameSource source;
  late RetroFrameImage picture;
  final slots = <FakeSlot>[];

  FakeSlot slot(int width, int height, List<int> pixel) {
    final made = FakeSlot(width, height)..fill(pixel);
    slots.add(made);
    return made;
  }

  setUp(() {
    source = FakeFrameSource();
    picture = RetroFrameImage(source.frames);
  });

  tearDown(() async {
    picture.dispose();
    await source.close();
    for (final made in slots) {
      made.free();
    }
    slots.clear();
  });

  test('an rgba8 frame becomes an image of its size and pixels', () async {
    source.send(slot(3, 2, [10, 20, 30, 255]).pin());
    await _shown(picture, 1);
    final image = picture.value!;
    expect((image.width, image.height), (3, 2));
    expect(await _rgba(image), List<int>.generate(24, (i) => [10, 20, 30, 255][i % 4]));
  });

  test('a bgra8 frame is read as blue, green, red, alpha', () async {
    source.send(slot(2, 2, [10, 20, 30, 255]).pin(format: RetroPixelFormat.bgra8));
    await _shown(picture, 1);
    expect(await _rgba(picture.value!), List<int>.generate(16, (i) => [30, 20, 10, 255][i % 4]));
  });

  test('a frame that is not drawn, or an empty event, is never shown', () async {
    source.send(slot(2, 2, [1, 2, 3, 255]).pin(epoch: 7), drawn: false);
    source.send(null, drawn: false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(picture.value, isNull);
    expect(picture.shown, 0);
  });

  test('the pixels are copied when the frame arrives, before the host can write the slot again', () async {
    final frame = slot(2, 1, [50, 60, 70, 255]);
    source.send(frame.pin());
    frame.fill([0, 0, 0, 255]);
    await _shown(picture, 1);
    expect(await _rgba(picture.value!), [50, 60, 70, 255, 50, 60, 70, 255]);
  });

  test('while one image is being made, only the newest frame that came meanwhile is made next', () async {
    source.send(slot(1, 1, [1, 0, 0, 255]).pin());
    source.send(slot(1, 1, [2, 0, 0, 255]).pin());
    source.send(slot(1, 1, [3, 0, 0, 255]).pin());
    await _shown(picture, 2);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(picture.shown, 2);
    expect(await _rgba(picture.value!), [3, 0, 0, 255]);
  });

  test('clear stops showing the picture and drops a frame still being made', () async {
    source.send(slot(1, 1, [9, 9, 9, 255]).pin());
    await _shown(picture, 1);
    var changes = 0;
    picture.addListener(() => changes++);
    source.send(slot(1, 1, [8, 8, 8, 255]).pin());
    picture.clear();
    expect(picture.value, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(picture.value, isNull);
    expect(changes, 1);
  });
}
