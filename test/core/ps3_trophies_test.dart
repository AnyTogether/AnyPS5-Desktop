import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/trophies.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('PS3 trophies join TRP definitions, localized text, and the managed profile', () {
    final root = Directory.systemTemp.createTempSync('anyps5-trophies-');
    addTearDown(() => root.deleteSync(recursive: true));
    final system = p.join(root.path, 'system');
    final game = Game(
      folder: p.join(root.path, 'game'),
      titleId: 'PS3-TEST00001',
      name: 'Test game',
      names: {},
      defaultLanguage: 'en-US',
      version: '01.00',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps3, path: p.join(root.path, 'game', 'PS3_DISC.SFB')),
    );
    const definition = '''
<trophyconf>
  <trophy id="000" hidden="no" ttype="P"/>
  <trophy id="003" hidden="yes" ttype="B"/>
</trophyconf>''';
    const defaultText = '''
<trophyconf><title-name>Default title</title-name>
  <trophy id="000"><name>Complete</name></trophy>
  <trophy id="003"><name>Secret &amp; safe</name><detail>Find it</detail></trophy>
</trophyconf>''';
    const frenchText = '''
<trophyconf><title-name>Titre</title-name>
  <trophy id="003"><name>Découverte</name></trophy>
</trophyconf>''';
    final archive = File(p.join(game.folder, 'PS3_GAME', 'TROPDIR', 'NPWR00001_00', 'TROPHY.TRP'))
      ..createSync(recursive: true);
    archive.writeAsBytesSync(
      _archive({
        'TROPCONF.SFM': utf8.encode(definition),
        'TROP.SFM': utf8.encode(defaultText),
        'TROP_02.SFM': utf8.encode(frenchText),
        'ICON0.PNG': [1, 2],
        'TROP003.PNG': [3, 4],
      }),
    );
    final unlocked = DateTime.utc(2026, 1, 2, 3, 4, 5);
    expect(Trophies.ps3ProgressStamp(game, system), isEmpty);
    final state = File(p.join(system, 'rpcs3', 'dev_hdd0', 'home', '00000001', 'trophy', 'NPWR00001_00', 'TROPUSR.DAT'))
      ..createSync(recursive: true);
    state.writeAsBytesSync(_userData(3, unlocked));
    final stamp = Trophies.ps3ProgressStamp(game, system);
    expect(stamp, isNotEmpty);

    final locked = Trophies.loadPs3(game)!;
    expect(locked.title, 'Default title');
    expect(locked.unlockedCount, 0);
    expect(locked.trophies.last.name, 'Secret & safe');
    final translated = Trophies.loadPs3(game, system: system, languages: ['fr-CA'])!;
    expect(translated.title, 'Titre');
    expect(translated.icon, [1, 2]);
    expect(translated.unlockedCount, 1);
    expect(translated.trophies.first.name, 'Complete');
    expect(translated.trophies.last.name, 'Découverte');
    expect(translated.trophies.last.detail, 'Find it');
    expect(translated.trophies.last.hidden, isTrue);
    expect(translated.trophies.last.icon, [3, 4]);
    expect(translated.trophies.last.unlocked, unlocked);
    expect(translated.trophies.last.grade, TrophyGrade.bronze);

    state.writeAsBytesSync([0x81, 0x8F, 0x54, 0xAD]);
    expect(Trophies.ps3ProgressStamp(game, system), isNot(stamp));
    expect(Trophies.loadPs3(game, system: system)?.unlockedCount, 0);
    archive.writeAsBytesSync([0xDC, 0xA2, 0x4D, 0]);
    expect(Trophies.loadPs3(game), isNull);
  });
}

Uint8List _archive(Map<String, List<int>> files) {
  const header = 0x40;
  const entrySize = 0x40;
  var offset = header + files.length * entrySize;
  final size = files.values.fold(offset, (total, file) => total + file.length);
  final bytes = Uint8List(size);
  final data = ByteData.sublistView(bytes)
    ..setUint32(0, 0xDCA24D00)
    ..setUint32(4, 1)
    ..setUint64(8, size)
    ..setUint32(0x10, files.length)
    ..setUint32(0x14, entrySize);
  var entry = header;
  for (final file in files.entries) {
    bytes.setAll(entry, ascii.encode(file.key));
    data
      ..setUint64(entry + 0x20, offset)
      ..setUint64(entry + 0x28, file.value.length);
    bytes.setAll(offset, file.value);
    offset += file.value.length;
    entry += entrySize;
  }
  return bytes;
}

Uint8List _userData(int trophy, DateTime time) {
  const table = 0x30;
  const entry = 0x50;
  final bytes = Uint8List(entry + 0x70);
  ByteData.sublistView(bytes)
    ..setUint32(0, 0x818F54AD)
    ..setUint32(8, 1)
    ..setUint32(table, 6)
    ..setUint32(table + 4, 0x60)
    ..setUint32(table + 0xC, 1)
    ..setUint64(table + 0x10, entry)
    ..setUint32(entry, 6)
    ..setUint32(entry + 4, 0x60)
    ..setUint32(entry + 0x10, trophy)
    ..setUint32(entry + 0x14, 1)
    ..setUint64(entry + 0x28, time.microsecondsSinceEpoch + Trophies.unixEpochTick);
  return bytes;
}
