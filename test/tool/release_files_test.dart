import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/release_files.dart';
import 'inno_installer_fixture.dart';

/// Reads the snapshot out of each kind of release file as its packaging writes it, from
/// SquashFS images made by mksquashfs, an LZMA2 stream made by liblzma and archives made here,
/// and refuses every other shape.
void main() {
  final fixtures = p.join('test', 'fixtures', 'release_files');
  const snapshotPath = 'usr/lib/anyps5-desktop/lib/libapp.so';
  const mark = 'AnyPS5 launcher test build';

  Uint8List text(int lines, String line) =>
      utf8.encode([for (var i = 0; i < lines; i++) '$line $i of a made-up AOT snapshot\n'].join());

  group('the AppImage', () {
    Uint8List appImage(String fixture, {int runtime = 200}) {
      final elf = Uint8List(runtime);
      elf.setAll(0, [0x7f, 0x45, 0x4c, 0x46, 2, 1]);
      ByteData.sublistView(elf)
        ..setUint64(0x28, runtime - 3 * 64, Endian.little)
        ..setUint16(0x3a, 64, Endian.little)
        ..setUint16(0x3c, 3, Endian.little);
      return Uint8List.fromList([...elf, ...File(p.join(fixtures, '$fixture.squashfs')).readAsBytesSync()]);
    }

    Uint8List snapshot({required bool test}) => Uint8List.fromList([
      ...utf8.encode('\x7fELF'),
      ...text(1800, 'snapshot line'),
      ...utf8.encode(test ? '...$mark...end\n' : 'end\n'),
    ]);

    test('the snapshot is read through data blocks, a stored block, fragments and every compressor', () {
      final stored = fileInAppImage(appImage('release-zstd'), snapshotPath);
      expect(stored.length, 219898);
      expect(sha256.convert(stored).toString(), '835ed20ca05e01f6d46578df63a021e372fc1ce7e920228c9efde0737c94a99f');
      expect(fileInAppImage(appImage('release-gzip'), snapshotPath), snapshot(test: false));
      expect(fileInAppImage(appImage('release-xz'), snapshotPath), snapshot(test: false));
      expect(fileInAppImage(appImage('test-zstd-fragments', runtime: 1024), snapshotPath), snapshot(test: true));
      expect(
        fileInAppImage(appImage('release-gzip'), 'usr/lib/anyps5-desktop/anyps5_desktop'),
        utf8.encode('\x7fELF launcher\n'),
      );
    });

    test('a path that is missing, a folder or a link is refused', () {
      final image = appImage('release-zstd');
      expect(() => fileInAppImage(image, 'usr/lib/anyps5-desktop/lib/libmissing.so'), throwsFormatException);
      expect(() => fileInAppImage(image, 'usr/lib/anyps5-desktop/lib'), throwsFormatException);
      expect(() => fileInAppImage(image, 'AppRun/lib/libapp.so'), throwsFormatException);
      expect(
        () => fileInAppImage(image, 'AppRun'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('not a file'))),
      );
    });

    test('anything but an ELF runtime with a SquashFS 4.0 image after it is refused', () {
      final image = appImage('release-zstd');
      expect(() => fileInAppImage(Uint8List.fromList(image.sublist(1)), snapshotPath), throwsFormatException);
      final shifted = appImage('release-zstd', runtime: 264);
      ByteData.sublistView(shifted).setUint64(0x28, 0, Endian.little);
      expect(() => fileInAppImage(shifted, snapshotPath), throwsFormatException);
      final lz4 = Uint8List.fromList(image);
      ByteData.sublistView(lz4).setUint16(200 + 20, 5, Endian.little);
      expect(
        () => fileInAppImage(lz4, snapshotPath),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('compressed'))),
      );
    });
  });

  group('the .deb', () {
    Uint8List ar(Map<String, List<int>> members) {
      final out = BytesBuilder()..add(ascii.encode('!<arch>\n'));
      members.forEach((name, data) {
        out
          ..add(ascii.encode('${name.padRight(16)}${'0'.padRight(12)}${'0'.padRight(6)}${'0'.padRight(6)}'))
          ..add(ascii.encode('${'100644'.padRight(8)}${'${data.length}'.padRight(10)}`\n'))
          ..add(data);
        if (data.length.isOdd) out.addByte(0x0a);
      });
      return out.takeBytes();
    }

    Uint8List tar(Map<String, List<int>> files) {
      final archive = Archive();
      files.forEach((name, data) => archive.addFile(ArchiveFile.bytes(name, data)));
      return TarEncoder().encodeBytes(archive);
    }

    final snapshot = text(10, 'deb');
    final data = tar({
      './opt/anyps5-desktop/anyps5_desktop': [1],
      './opt/anyps5-desktop/lib/libapp.so': snapshot,
    });

    test('the snapshot is read from data.tar, compressed as dpkg-deb can or not', () {
      for (final (name, member) in [
        ('data.tar.xz', XZEncoder().encodeBytes(data)),
        ('data.tar.zst', ZstdEncoder().encodeBytes(data)),
        ('data.tar.gz', gzip.encode(data)),
        ('data.tar', data),
      ]) {
        final deb = ar({
          'debian-binary': ascii.encode('2.0\n'),
          'control.tar.xz': XZEncoder().encodeBytes(tar({})),
          name: member,
        });
        expect(fileInDeb(deb, 'opt/anyps5-desktop/lib/libapp.so'), snapshot, reason: name);
      }
    });

    test('a .deb without data, damaged, or compressed otherwise is refused', () {
      expect(() => fileInDeb(ar({'debian-binary': ascii.encode('2.0\n')}), 'a'), throwsFormatException);
      expect(
        () => fileInDeb(
          ar({
            'data.tar.bz2': [0],
          }),
          'a',
        ),
        throwsFormatException,
      );
      expect(() => fileInDeb(Uint8List.fromList(utf8.encode('PK not an ar')), 'a'), throwsFormatException);
      final cut = ar({'data.tar': data});
      expect(() => fileInDeb(Uint8List.sublistView(cut, 0, cut.length - 100), 'a'), throwsFormatException);
    });
  });

  group('the archives', () {
    final snapshot = text(10, 'zip');

    test("the Windows zip's data/app.so, written with / or \\ between names", () {
      for (final name in ['data/app.so', r'data\app.so', './data/app.so']) {
        final zip = ZipEncoder().encodeBytes(Archive()..addFile(ArchiveFile.bytes(name, snapshot)));
        expect(ReleaseFile.windowsZip.snapshotIn(zip), snapshot, reason: name);
      }
    });

    test('a zip whose snapshot does not match its CRC-32 is refused', () {
      final zip = ZipEncoder().encodeBytes(
        Archive()..addFile(ArchiveFile.bytes('data/app.so', snapshot)..compression = CompressionType.none),
      );
      expect(ReleaseFile.windowsZip.snapshotIn(zip), snapshot);
      final damaged = Uint8List.fromList(zip);
      damaged[indexOfBytes(damaged, snapshot) + 5] ^= 1;
      expect(
        () => ReleaseFile.windowsZip.snapshotIn(damaged),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('CRC-32'))),
      );
    });

    test('a missing, doubled or linked snapshot is refused', () {
      final twice = ZipEncoder().encodeBytes(
        Archive()
          ..addFile(ArchiveFile.bytes('data/app.so', snapshot))
          ..addFile(ArchiveFile.bytes(r'data\app.so', snapshot)),
      );
      expect(() => ReleaseFile.windowsZip.snapshotIn(twice), throwsFormatException);
      final elsewhere = ZipEncoder().encodeBytes(Archive()..addFile(ArchiveFile.bytes('x/data/app.so', snapshot)));
      expect(() => ReleaseFile.windowsZip.snapshotIn(elsewhere), throwsFormatException);
      final linked = gzip.encode(
        TarEncoder().encodeBytes(Archive()..addFile(ArchiveFile.symlink('AnyPS5-Desktop/lib/libapp.so', 'other.so'))),
      );
      expect(() => ReleaseFile.linuxTar.snapshotIn(Uint8List.fromList(linked)), throwsFormatException);
    });

    test('release files are told by the names the packaging gives them', () {
      expect(ReleaseFile.named('AnyPS5-Desktop-Setup-0.1.25-x64.exe'), ReleaseFile.installer);
      expect(ReleaseFile.named('AnyPS5-Desktop-windows-x64.zip'), ReleaseFile.windowsZip);
      expect(ReleaseFile.named('AnyPS5-Desktop-linux-x64.tar.gz'), ReleaseFile.linuxTar);
      expect(ReleaseFile.named('anyps5-desktop_0.1.25_amd64.deb'), ReleaseFile.deb);
      expect(ReleaseFile.named('AnyPS5-Desktop-0.1.25-x86_64.AppImage'), ReleaseFile.appImage);
      for (final name in ['SHA256SUMS', 'AnyPS5-Desktop.dmg', 'notes.md', 'AnyPS5-Desktop.tar.xz']) {
        expect(ReleaseFile.named(name), isNull, reason: name);
      }
    });
  });

  group('the Windows installer', () {
    test('every chunk of its file data is read, compressed by liblzma or stored', () {
      final compressed = File(p.join(fixtures, 'installer-files.lzma2')).readAsBytesSync();
      final expected = utf8.encode(
        [for (var i = 0; i < 6000; i++) 'installed file line $i of a made-up launcher\n'].join(),
      );
      final stored = utf8.encode('a stored chunk');
      final exe = innoInstaller([
        [16, ...compressed],
        [0, ...lzma2Stored(stored)],
      ]);
      expect(installerData(exe), [...expected, ...stored]);
    });

    test('an installer laid out otherwise is refused', () {
      final good = innoInstaller([
        [
          0,
          ...lzma2Stored([1, 2, 3]),
        ],
      ]);
      expect(installerData(good), [1, 2, 3]);
      Uint8List changed(void Function(Uint8List bytes, ByteData data, int table) change) {
        final bytes = Uint8List.fromList(good);
        change(bytes, ByteData.sublistView(bytes), indexOfBytes(bytes, innoOffsetTableId));
        return bytes;
      }

      for (final (why, bytes) in [
        ('no offset table', Uint8List.fromList(good.sublist(0, 100))),
        ('another table version', changed((b, d, t) => d.setUint32(t + 12, 1, Endian.little))),
        ('a damaged table', changed((b, d, t) => b[t + 50]++)),
        ('no zlb chunk', changed((b, d, t) => b[d.getUint64(t + 48, Endian.little)] = 0x41)),
        (
          'no end marker',
          innoInstaller([
            [
              0,
              ...lzma2Stored([1, 2, 3]).sublist(0, 6),
            ],
          ]),
        ),
        (
          'a control byte LZMA2 has not',
          innoInstaller([
            [0, 3, 0, 0],
          ]),
        ),
        (
          'a dictionary LZMA2 has not',
          innoInstaller([
            [41, 0],
          ]),
        ),
      ]) {
        expect(() => installerData(bytes), throwsFormatException, reason: why);
      }
    });
  });
}
