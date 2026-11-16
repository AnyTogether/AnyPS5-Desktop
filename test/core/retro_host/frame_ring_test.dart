import 'dart:ffi';

import 'package:anyps5_desktop/core/retro_host/frame_ring.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

/// A ring in plain memory, laid out as protocol.md "Frame ring" says, with slots of 16 bytes.
class _Memory {
  _Memory() : base = calloc<Uint8>(bytes) {
    final header = base.cast<Uint32>();
    header[0] = 0x46523541;
    header[1] = 1;
    header[2] = 3;
    header[3] = 4096;
    (base + 16).cast<Uint64>().value = slotBytes;
    header[6] = 0xFFFFFFFF;
    header[7] = 0xFFFFFFFF;
    header[8] = 1;
  }

  static const slotBytes = 16;
  static const bytes = 4096 + 3 * slotBytes;
  final Pointer<Uint8> base;

  void slot(int index, {int width = 2, int height = 2, int epoch = 1}) {
    final fields = (base + 40 + 24 * index).cast<Uint32>();
    fields[0] = width;
    fields[1] = height;
    fields[2] = 1;
    fields[3] = epoch;
  }

  int get reading => base.cast<Uint32>()[7];
  set latest(int value) => base.cast<Uint32>()[6] = value;
}

void main() {
  late _Memory memory;
  setUp(() => memory = _Memory());
  tearDown(() => calloc.free(memory.base));

  FrameRing ring({int Function(Pointer<Void>)? load}) => FrameRing.check(
    base: memory.base.cast(),
    bytes: _Memory.bytes,
    pixelFormat: RetroPixelFormat.rgba8,
    load: load ?? (address) => address.cast<Uint32>().value,
    store: (address, value) => address.cast<Uint32>().value = value,
  );

  test('pins the newest frame and says the earlier pin was given up', () {
    memory.slot(1);
    memory.latest = 1;
    final frames = ring();
    final pinned = frames.pin();
    expect(pinned?.slot, 1);
    expect(memory.reading, 1);
    expect(frames.gaveUpPin, isTrue);
  });

  test('with no frame, keeps the earlier pin', () {
    final frames = ring();
    expect(frames.pin(), isNull);
    expect(frames.gaveUpPin, isFalse);
    expect(memory.reading, 0xFFFFFFFF);
  });

  test('when latest keeps moving for three tries, pins nothing and has given up the earlier pin', () {
    memory
      ..slot(0)
      ..slot(1)
      ..slot(2);
    var loads = 0;
    final frames = ring(load: (_) => [1, 2, 2, 0, 0, 1][loads++ % 6]);
    expect(frames.pin(), isNull);
    expect(frames.gaveUpPin, isTrue, reason: 'reading moved, so the frame shown before is no longer protected');
  });

  test('refuses a frame that does not fit its slot', () {
    memory.slot(0, width: 4, height: 4);
    memory.latest = 0;
    expect(() => ring().pin(), throwsA(isA<RetroProtocolError>()));
  });
}
