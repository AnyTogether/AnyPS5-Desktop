import 'dart:io';

import 'package:anyps5_desktop/core/game_archives.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/ffpfsc_builder.dart';
import '../support/fixtures.dart';

/// A game dropped into the games folder as one .ffpfsc: found, read as a plan, unpacked with the
/// zip flow into the folder beside it, and refused with a true message when out of shape.
void main() {
  late Directory temp;
  late String root;

  setUp(() {
    temp = temporaryFolder('ffpfsc');
    root = p.join(temp.path, 'Games');
    Directory(root).createSync(recursive: true);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  String file([String name = 'Small.ffpfsc']) => p.join(root, name);

  void expectDamaged(TestFfpfsc image, [String name = 'Small.ffpfsc']) {
    image.write(file(name));
    expect(() => GameArchives.plan(file(name)), throwsA(predicate((error) => error.toString().contains('damaged'))));
  }

  test('a game file unpacks beside it byte for byte, its name, title ID and icon read', () async {
    final image = TestFfpfsc(TestFfpfsc.game());
    image.write(file());
    final found = GameArchives.find([root]);
    expect(found.map((archive) => archive.name), ['Small.ffpfsc']);
    final archive = found.single;
    expect(archive.isFfpfsc, isTrue);
    expect(p.basename(archive.folder), 'Small');

    final plan = GameArchives.plan(archive.path);
    expect(plan.looksLikeGame, isTrue);
    expect(plan.strip, '');
    expect(plan.titleId, 'PPSA07007');
    expect(plan.version, '01.000.000');
    expect(plan.titleName, 'Small Quest');
    expect(plan.files, 5);
    expect(plan.size, 3000 + 150000 + TestFfpfsc.game()[4].data.length + TestFfpfsc.pngStub.length);
    expect(plan.icon, isNotNull);
    expect(plan.refused, isEmpty);
    expect(plan.problem, isNull);

    final heard = <(int, int)>[];
    await GameArchives.unpack(archive, progress: (done, total) => heard.add((done, total)));
    expect(heard.last.$1, plan.size);
    for (final item in TestFfpfsc.game()) {
      if (item.directory) continue;
      expect(
        File(p.joinAll([archive.folder, ...item.path.split('/')])).readAsBytesSync(),
        item.data,
        reason: item.path,
      );
    }
    expect(Directory(archive.partial).existsSync(), isFalse);
    expect(GameArchives.find([root]), isEmpty, reason: 'unpacked: a folder of its name stands beside it');
  });

  test('a file with no game in it is read but is no game', () {
    TestFfpfsc([FfpfscItem('notes.txt', data: 'hello'.codeUnits)]).write(file());
    final plan = GameArchives.plan(file());
    expect(plan.looksLikeGame, isFalse);
    expect(plan.files, 1);
  });

  test('an existing folder is never written over', () async {
    final image = TestFfpfsc(TestFfpfsc.game());
    image.write(file());
    final folder = Directory(p.join(root, 'Small'))..createSync();
    final marker = File(p.join(folder.path, 'mine.txt'))..writeAsStringSync('keep');
    expect(GameArchives.find([root]), isEmpty, reason: 'a folder of its name is there: not offered');
    final archive = GameArchive(path: file(), size: image.bytes.length);
    await expectLater(GameArchives.unpack(archive), throwsA(isA<FileSystemException>()));
    expect(() => GameArchives.unpackSync(file(), folder.path), throwsA(anything));
    expect(marker.readAsStringSync(), 'keep');
  });

  test('a stop leaves nothing behind', () {
    TestFfpfsc(TestFfpfsc.game()).write(file());
    final into = p.join(root, 'out');
    expect(() => GameArchives.unpackSync(file(), into, cancelled: () => true), throwsA(isA<UnpackCancelled>()));
    expect(Directory(into).existsSync(), isFalse);
  });

  group('malformed', () {
    test('not a PFS image', () {
      final image = TestFfpfsc(TestFfpfsc.game());
      expectDamaged(image.put64(0, 8));
      File(file()).writeAsStringSync('not one');
      expect(() => GameArchives.plan(file()), throwsA(anything));
    });

    test('truncation at every stage', () {
      final image = TestFfpfsc(TestFfpfsc.game());
      for (final size in [200, 0x900, image.pfscStart + 0x40, image.innerStart + 0x200, image.bytes.length - 1]) {
        final cut = image.copy()..bytes = image.bytes.sublist(0, size);
        expectDamaged(cut, 'cut$size.ffpfsc');
      }
    });

    test('offsets past the end', () {
      final image = TestFfpfsc(TestFfpfsc.game());
      const bs = TestFfpfsc.blockSize;
      // Outer inode 3 (pfs_image.dat): its first block far past the file.
      expectDamaged(image.put32(0x7FFFFFFF, bs + 3 * 0xA8 + 0x64));
      // A block count past the file, outer and inner.
      expectDamaged(image.put64(1 << 40, 0x38));
      expectDamaged(image.put64(1 << 40, image.innerStart + 0x38));
      // A count of inodes past its table.
      expectDamaged(image.put64(100000, image.innerStart + 0x30));
      // A file's bytes past its blocks: inner inode 5 is eboot.bin.
      expectDamaged(image.put64(bs * 50, image.innerInode(5) + 8));
      // The PFSC table: its first entry not at the data, a later one out of order.
      expectDamaged(image.put64(0, image.pfscStart + 0x400));
      expectDamaged(image.put64(1, image.pfscStart + 0x408));
    });

    test('paths that escape, or names no system can make, are refused', () {
      const cases = {
        'dots': '..',
        'slash': '../evil.dll',
        'absolute': '/etc/passwd',
        'back': r'..\evil',
        'drive': 'C:evil',
        'device': 'con.txt',
        'dot': 'trailing.',
      };
      for (final MapEntry(key: name, value: raw) in cases.entries) {
        final items = [
          ...TestFfpfsc.game(),
          FfpfscItem('x', data: const [1], rawName: raw),
        ];
        TestFfpfsc(items).write(file('$name.ffpfsc'));
        final plan = GameArchives.plan(file('$name.ffpfsc'));
        expect(plan.refused, hasLength(1), reason: raw);
        final into = p.join(root, 'o-$name');
        expect(() => GameArchives.unpackSync(file('$name.ffpfsc'), into), throwsA(anything), reason: raw);
        expect(Directory(into).existsSync(), isFalse, reason: raw);
      }
    });

    test('a link is refused', () {
      TestFfpfsc([
        ...TestFfpfsc.game(),
        const FfpfscItem('l', data: [1], type: 6),
      ]).write(file('typed.ffpfsc'));
      expect(GameArchives.plan(file('typed.ffpfsc')).refused, hasLength(1));
      TestFfpfsc([
        ...TestFfpfsc.game(),
        const FfpfscItem('l', data: [1], mode: 0xA16D),
      ]).write(file('moded.ffpfsc'));
      expect(GameArchives.plan(file('moded.ffpfsc')).refused, hasLength(1));
    });

    test('compressed is said', () {
      final image = TestFfpfsc(TestFfpfsc.game());
      // The table says each block is 0x8000 bytes: as a compressed one would be.
      final table = image.pfscStart + 0x400;
      final first = image.get64(table);
      final packed = image.copy();
      for (var index = 1; index <= image.blocks; index++) {
        packed.set(first + index * 0x8000, table + index * 8, 8);
      }
      packed.write(file());
      expect(GameArchives.plan(file()).problem, ArchiveProblem.compressed);
      expect(() => GameArchives.unpackSync(file(), p.join(root, 'o')), throwsA(anything));
      // A file inside flagged as PFSC compressed.
      image.put32(0x11, image.innerInode(5) + 4).write(file('inside.ffpfsc'));
      expect(GameArchives.plan(file('inside.ffpfsc')).problem, ArchiveProblem.compressed);
    });

    test('other layouts are said to be unsupported', () {
      final image = TestFfpfsc(TestFfpfsc.game());
      void unsupported(TestFfpfsc tampered, String name) {
        tampered.write(file('$name.ffpfsc'));
        expect(GameArchives.plan(file('$name.ffpfsc')).problem, ArchiveProblem.unsupported, reason: name);
      }

      // Encrypted (mode bit 4), outer and inner.
      unsupported(image.copy()..set(4, 0x1C, 2), 'enc');
      unsupported(image.copy()..set(4, image.innerStart + 0x1C, 2), 'enc2');
      // A block size that is not a power of two.
      unsupported(image.put32(0x1800, 0x20), 'bs');
      // A PFSC block size other than 64 KiB.
      unsupported(image.put32(0x8000, image.pfscStart + 12), 'pb');
      // A second file in the outer image.
      unsupported(
        TestFfpfsc(
          TestFfpfsc.game(),
          outerExtra: [
            const FfpfscItem('more.bin', data: [1]),
          ],
        ),
        'two',
      );
      // pfs_image.dat without the PFSC flag.
      unsupported(image.put32(0x10, TestFfpfsc.blockSize + 3 * 0xA8 + 4), 'noflag');
      // A file in more than one piece.
      unsupported(image.put32(99, image.innerInode(5) + 0x68), 'frag');
    });

    test('loops and shared files are refused', () {
      final image = TestFfpfsc(TestFfpfsc.game());
      // uroot's "sce_sys" entry pointing back to uroot (inode 2): a directory loop.
      expectDamaged(image.put32(2, image.find('sce_sys', image.innerStart) - 16));
      // A second name for one file: "empty.dat" pointed at eboot.bin's inode.
      expectDamaged(image.put32(5, image.find('empty.dat', image.innerStart) - 16));
    });

    test('depth is bounded', () {
      final deep = <FfpfscItem>[];
      var path = '';
      for (var level = 0; level < 40; level++) {
        path += level == 0 ? 'd' : '/d';
        deep.add(FfpfscItem(path, directory: true));
      }
      expectDamaged(
        TestFfpfsc([
          ...deep,
          FfpfscItem('$path/f', data: const [1]),
        ]),
      );
    });

    test('an unreadable param.json and no icon stay unread', () {
      final items = [
        for (final item in TestFfpfsc.game())
          if (item.path == 'sce_sys/param.json')
            FfpfscItem(item.path, data: 'not json'.codeUnits)
          else if (item.path != 'sce_sys/icon0.png')
            item,
      ];
      TestFfpfsc(items).write(file());
      final plan = GameArchives.plan(file());
      expect(plan.titleId, isNull);
      expect(plan.titleName, isNull);
      expect(plan.icon, isNull);
      expect(plan.looksLikeGame, isTrue);
    });

    test('an icon too large to decode is left out', () {
      final items = [
        for (final item in TestFfpfsc.game())
          if (item.path == 'sce_sys/icon0.png')
            FfpfscItem(item.path, data: [...item.data]..setRange(18, 19, const [0x20]))
          else
            item,
      ];
      TestFfpfsc(items).write(file());
      expect(GameArchives.plan(file()).icon, isNull);
    });
  });
}
