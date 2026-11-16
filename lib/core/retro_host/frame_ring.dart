import 'dart:ffi';

import 'retro_host_native.dart';
import 'retro_host_protocol.dart';

/// One frame the launcher has pinned in a [FrameRing]: the host does not write this slot until the
/// launcher's next read. Every field is the launcher's own checked copy (protocol.md "Frame ring").
class PinnedFrame {
  const PinnedFrame({
    required this.slot,
    required this.width,
    required this.height,
    required this.epoch,
    required this.visible,
    required this.pixels,
    required this.pixelFormat,
  });

  final int slot;
  final int width;
  final int height;
  final int epoch;

  /// Whether the frame has any pixel that is not black.
  final bool visible;

  /// `height` rows of `width` × 4 bytes, top row first, no padding.
  final Pointer<Uint8> pixels;

  /// [RetroPixelFormat.rgba8] or [RetroPixelFormat.bgra8].
  final String pixelFormat;
}

/// The shared memory a `ring` message announces, mapped and checked as protocol.md "Checks the
/// launcher makes" says. The header's geometry is read once, here; later reads use only the copies.
class FrameRing {
  FrameRing._(this._base, this.bytes, this.slotBytes, this.pixelFormat, this._load, this._store);

  Pointer<Void> _at(int offset) => (_base.cast<Uint8>() + offset).cast();

  static const _magic = 0x46523541;
  static const _none = 0xFFFFFFFF;
  static const _headerBytes = 4096;
  static const _maxSlotBytes = 268435456;
  static const _maxSide = 8192;

  final Pointer<Void> _base;
  final int bytes;
  final int slotBytes;
  final String pixelFormat;
  final int Function(Pointer<Void>) _load;
  final void Function(Pointer<Void>, int) _store;
  bool _unmapped = false;

  /// Whether the last [pin] stored a slot in `reading`, which gives up the pin held before it,
  /// whether or not it pinned a new frame.
  bool get gaveUpPin => _gaveUpPin;
  bool _gaveUpPin = false;

  /// Checks the mapped header at [base] against the `ring` message's [bytes], the pixel format
  /// `welcome` agreed and, when there is one, the [current] ring the new one must outgrow. Throws
  /// [RetroProtocolError] when a check fails; the caller then unmaps [base].
  static FrameRing check({
    required Pointer<Void> base,
    required int bytes,
    required String pixelFormat,
    FrameRing? current,
    int Function(Pointer<Void>) load = retroHostLoad,
    void Function(Pointer<Void>, int) store = retroHostStore,
  }) {
    final header = base.cast<Uint32>();
    if (header[0] != _magic) throw const RetroProtocolError('The ring\'s magic is wrong.');
    if (header[1] != 1) throw const RetroProtocolError('The ring\'s version is not 1.');
    if (header[2] != 3) throw const RetroProtocolError('The ring does not have 3 slots.');
    if (header[3] != _headerBytes) throw const RetroProtocolError('The ring\'s header is not 4096 bytes.');
    if (header[8] != RetroPixelFormat.code(pixelFormat)) {
      throw const RetroProtocolError('The ring\'s pixel format is not the one welcome agreed.');
    }
    final slotBytes = (base.cast<Uint8>() + 16).cast<Uint64>().value;
    if (slotBytes < 4 || slotBytes > _maxSlotBytes || slotBytes % 4 != 0) {
      throw const RetroProtocolError('The ring\'s slotBytes is out of range.');
    }
    if (_headerBytes + 3 * slotBytes != bytes) {
      throw const RetroProtocolError('The ring\'s size does not match its header.');
    }
    if (current != null) {
      final twice = current.slotBytes * 2;
      final needed = twice < _maxSlotBytes ? twice : _maxSlotBytes;
      if (slotBytes <= current.slotBytes || slotBytes < needed) {
        throw const RetroProtocolError('A new ring is not at least twice as large as the last.');
      }
    }
    return FrameRing._(base, bytes, slotBytes, pixelFormat, load, store);
  }

  /// Pins the newest frame: null when there is none, or when `latest` kept moving for three tries.
  /// In that second case the frame pinned before is given up too ([gaveUpPin]), so the caller must
  /// stop showing it. Throws [RetroProtocolError] for a `latest` outside
  /// 0 to 2 or a slot whose size breaks the rules.
  PinnedFrame? pin() {
    final latestAddress = _at(24);
    final readingAddress = _at(28);
    int? slot;
    _gaveUpPin = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      final latest = _load(latestAddress);
      if (latest == _none) return null;
      if (latest > 2) throw RetroProtocolError('The ring\'s latest is $latest.');
      _store(readingAddress, latest);
      _gaveUpPin = true;
      if (_load(latestAddress) == latest) {
        slot = latest;
        break;
      }
    }
    if (slot == null) return null;
    final fields = _at(40 + 24 * slot).cast<Uint32>();
    final width = fields[0];
    final height = fields[1];
    final visible = fields[2];
    final epoch = fields[3];
    if (width < 1 || width > _maxSide || height < 1 || height > _maxSide) {
      throw RetroProtocolError('A frame of $width x $height is outside 1 to 8192 pixels a side.');
    }
    if (width * height * 4 > slotBytes) {
      throw RetroProtocolError('A frame of $width x $height does not fit its slot.');
    }
    return PinnedFrame(
      slot: slot,
      width: width,
      height: height,
      epoch: epoch,
      visible: visible != 0,
      pixels: _at(_headerBytes + slot * slotBytes).cast<Uint8>(),
      pixelFormat: pixelFormat,
    );
  }

  void unmap() {
    if (_unmapped) return;
    _unmapped = true;
    retroHostUnmapRing(_base, bytes);
  }
}
