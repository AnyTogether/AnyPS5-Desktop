import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:anyps5_desktop/core/audio/atrac9.dart';
import 'package:anyps5_desktop/core/audio/theme_music.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_audio.dart';

/// The config bytes of a real 48 kHz stereo snd0.at9.
const stereoConfig = [0xfe, 0x74, 0x0f, 0xf0];

/// An ATRAC9 RIFF file's chunks around [data], as the PS5's encoder lays them out.
Uint8List at9File({
  int channels = 2,
  int sampleRate = 48000,
  int blockAlign = 512,
  List<int> config = stereoConfig,
  int? totalFrames,
  int delay = 256,
  (int, int)? loop,
  List<int> data = const [],
  bool atrac9 = true,
}) {
  final out = BytesBuilder();
  void u16(int value) => out.add([value & 0xff, value >> 8 & 0xff]);
  void u32(int value) => out.add([value & 0xff, value >> 8 & 0xff, value >> 16 & 0xff, value >> 24 & 0xff]);
  final body = BytesBuilder();
  void chunk(String id, void Function() write) {
    final start = out.length;
    write();
    final bytes = out.takeBytes();
    body
      ..add(id.codeUnits)
      ..add([bytes.length & 0xff, bytes.length >> 8 & 0xff, bytes.length >> 16 & 0xff, bytes.length >> 24 & 0xff])
      ..add(bytes);
    if (bytes.length.isOdd) body.addByte(0);
    assert(start == 0);
  }

  chunk('fmt ', () {
    u16(0xfffe);
    u16(channels);
    u32(sampleRate);
    u32(sampleRate * 2);
    u16(blockAlign);
    u16(0);
    u16(22);
    u16(1024);
    u32(3);
    out.add(atrac9 ? ThemeSong.atrac9Format : List.filled(16, 7));
    u32(1);
    out.add(config);
    u32(0);
  });
  chunk('fact', () {
    u32(totalFrames ?? 0);
    u32(delay);
    u32(delay);
  });
  if (loop != null) {
    chunk('smpl', () {
      for (var index = 0; index < 7; index++) {
        u32(index == 0 || index == 1 ? 0 : (index == 2 ? 20833 : 0));
      }
      u32(1);
      u32(0);
      u32(0);
      u32(0);
      u32(loop.$1);
      u32(loop.$2 - 1);
      u32(0);
      u32(0);
    });
  }
  chunk('data', () => out.add(data));
  final chunks = body.takeBytes();
  final file = BytesBuilder()
    ..add('RIFF'.codeUnits)
    ..add([(chunks.length + 4) & 0xff, (chunks.length + 4) >> 8 & 0xff, (chunks.length + 4) >> 16 & 0xff, 0])
    ..add('WAVE'.codeUnits)
    ..add(chunks);
  return file.takeBytes();
}

Game game(String name, {String? music, RetroDisc? retro}) => Game(
  folder: '/games/$name',
  titleId: 'PPSA00001',
  name: name,
  names: {'en-US': name},
  defaultLanguage: 'en-US',
  version: '01.000.000',
  executable: ExecutableKind.elf,
  music: music,
  retro: retro,
);

double rms(Iterable<double> samples) {
  var sum = 0.0;
  var count = 0;
  for (final sample in samples) {
    sum += sample * sample;
    count++;
  }
  return count == 0 ? 0 : math.sqrt(sum / count);
}

void main() {
  group('ThemeSong', () {
    test('reads the format, the length, the delay and the loop of an ATRAC9 file', () {
      final header = ThemeSong.header(
        at9File(totalFrames: 96000, delay: 256, loop: (1000, 90000), data: List.filled(1024, 0)),
      );
      expect(header.channels, 2);
      expect(header.sampleRate, 48000);
      expect(header.blockAlign, 512);
      expect(header.config, stereoConfig);
      expect(header.totalFrames, 96000);
      expect(header.delay, 256);
      expect(header.loop, (1000, 90000));
      expect(header.dataEnd - header.dataStart, 1024);
    });

    test('a loop past the song is left out', () {
      final header = ThemeSong.header(at9File(totalFrames: 1000, loop: (10, 2000), data: [1, 2]));
      expect(header.loop, isNull);
    });

    test('says what is wrong with a file it cannot play', () {
      Matcher says(String text) =>
          throwsA(isA<ThemeSongUnreadable>().having((error) => error.message, 'message', text));
      expect(() => ThemeSong.header(Uint8List.fromList('not audio at all'.codeUnits)), says('not a RIFF WAVE file'));
      expect(() => ThemeSong.header(at9File(atrac9: false, data: [1])), says('not ATRAC9'));
      expect(() => ThemeSong.header(at9File()), says('no audio data'));
      expect(() => ThemeSong.header(at9File(channels: 0, data: [1])), says('an empty format'));
    });

    test('LibAtrac9, built with the launcher, reads the config of a stereo theme song', () {
      final info = ThemeSong.codecInfo(Uint8List.fromList(stereoConfig));
      expect(info, isNotNull);
      expect(info!.channels, 2);
      expect(info.frameSamples, 256);
      expect(info.framesInSuperframe, 4);
      expect(ThemeSong.codecInfo(Uint8List.fromList([0, 0, 0, 0])), isNull);
    });

    test('a config that does not match the file is refused', () {
      expect(
        () => ThemeSong.decode(at9File(channels: 1, data: List.filled(512, 0))),
        throwsA(isA<ThemeSongUnreadable>()),
      );
    });

    test('ready to play: the song up to the end of its loop, repeating from its start', () {
      final song = ThemeSong(sampleRate: 48000, channels: 2, samples: Float32List(2 * 96000), loop: (24000, 72000));
      final looped = song.playable();
      expect(looped.wav.length, 44 + 72000 * 4);
      expect(looped.loopStart, const Duration(milliseconds: 500));
      final whole = ThemeSong(
        sampleRate: 48000,
        channels: 2,
        samples: Float32List(2 * 96000),
        loop: (0, 72000),
      ).playable();
      expect(whole.wav.length, 44 + 96000 * 4);
      expect(whole.loopStart, Duration.zero);
    });

    // A real dump's song, when one is at hand (ANYPS5_SND0=path/to/snd0.at9).
    final sample = Platform.environment['ANYPS5_SND0'];
    test('decodes a real snd0.at9 to its length, without the encoder delay', () async {
      final file = File(sample!).readAsBytesSync();
      final header = ThemeSong.header(file);
      final song = ThemeSong.decode(file);
      expect(song.channels, header.channels);
      expect(song.sampleRate, header.sampleRate);
      if (header.totalFrames > 0) expect(song.frames, header.totalFrames);
      expect(song.loop, header.loop);
      expect(rms(song.samples), greaterThan(0.005));
      expect(song.samples.every((sample) => sample.abs() < 2), isTrue);
      final playable = await ThemeSong.load(sample);
      expect(playable, isNotNull);
    }, skip: sample == null ? 'set ANYPS5_SND0 to a snd0.at9 to decode a real song' : false);
  });

  group('ThemeMusic', () {
    PlayableSong song(String path) => PlayableSong(Uint8List.fromList(path.codeUnits), const Duration(seconds: 2));

    test('a console cue plays once per selection and gives way to looping game music', () {
      fakeAsync((async) {
        final out = FakeAudio();
        final music = ThemeMusic(out);
        const cue = '/console-audio/ps1-startup.wav';

        music.play(null, startupCue: cue);
        async.elapse(const Duration(milliseconds: 219));
        expect(out.voices, isEmpty);
        async.elapse(const Duration(milliseconds: 2));
        final startup = out.voices.single;
        expect(startup.sound.name, cue);
        expect(startup.loop, isFalse);
        music.play(null, startupCue: cue);
        async.elapse(const Duration(seconds: 12));
        expect(out.voices, [startup]);

        final retro = game(
          'Crash 2',
          music: '/games/crash2/theme.wav',
          retro: (platform: RetroPlatform.ps1, path: '/disc'),
        );
        music.play(retro);
        async.elapse(const Duration(seconds: 2));
        expect(startup.stopped, isTrue);
        expect(out.voices.last.sound.name, '/games/crash2/theme.wav');
        expect(out.voices.last.loop, isTrue);

        music.play(null, startupCue: cue);
        async.elapse(const Duration(milliseconds: 250));
        expect(out.voices.last.sound.name, cue);
        expect(out.voices.last.loop, isFalse);
        expect(out.voices, hasLength(3));
      });
    });

    test('PS1 and PS2 preview music uses ordinary file playback and the existing fades', () {
      for (final platform in RetroPlatform.ps1AndPs2) {
        fakeAsync((async) {
          final out = FakeAudio();
          final music = ThemeMusic(out, decode: (_) => throw StateError('A retro song is ordinary audio.'));
          music.play(
            game(platform.name, music: '/${platform.name}/theme.wav', retro: (platform: platform, path: '/disc')),
          );
          async.elapse(const Duration(seconds: 3));
          expect(out.voices.single.sound.name, '/${platform.name}/theme.wav');
          expect(out.voices.single.loop, isTrue);
          expect(out.voices.single.volume, closeTo(0.5, 1e-9));
          music.play(null);
          async.elapse(const Duration(seconds: 1));
          expect(out.voices.single.stopped, isTrue);
        });
      }
    });

    test('a game\'s song comes in after the selection rests, then fades in to the volume', () {
      fakeAsync((async) {
        final out = FakeAudio();
        final decoded = <String>[];
        final music = ThemeMusic(
          out,
          decode: (path) async {
            decoded.add(path);
            return song(path);
          },
        );
        music.play(game('stray', music: '/games/stray/sce_sys/snd0.at9'));
        async.elapse(const Duration(milliseconds: 899));
        expect(out.voices, isEmpty);
        async.elapse(const Duration(milliseconds: 2));
        expect(decoded, ['/games/stray/sce_sys/snd0.at9']);
        final voice = out.voices.single;
        expect(voice.loop, isTrue);
        expect(voice.loopStart, const Duration(seconds: 2));
        expect(voice.volumes.first, 0);
        expect(music.playing, '/games/stray');
        async.elapse(const Duration(milliseconds: 700));
        expect(voice.volume, inExclusiveRange(0.15, 0.35), reason: 'halfway: eased');
        async.elapse(const Duration(milliseconds: 800));
        expect(voice.volume, closeTo(0.5, 1e-9));
        for (var index = 1; index < voice.volumes.length; index++) {
          expect(voice.volumes[index], greaterThanOrEqualTo(voice.volumes[index - 1]));
        }
        music.volume = 0.8;
        expect(voice.volume, 0.8);
      });
    });

    test('moving on fades the song out and stops it; the same game again changes nothing', () {
      fakeAsync((async) {
        final out = FakeAudio();
        final music = ThemeMusic(out, decode: (path) async => song(path));
        final first = game('first', music: '/a.at9');
        music.play(first);
        async.elapse(const Duration(seconds: 3));
        final voice = out.voices.single;
        music.play(first);
        async.elapse(const Duration(seconds: 3));
        expect(out.voices, hasLength(1));
        music.play(game('silent'));
        expect(music.playing, isNull);
        async.elapse(const Duration(milliseconds: 200));
        expect(voice.stopped, isFalse);
        expect(voice.volume, inExclusiveRange(0, 0.5));
        async.elapse(const Duration(milliseconds: 300));
        expect(voice.stopped, isTrue);
        expect(voice.volume, 0);
        async.elapse(const Duration(seconds: 3));
        expect(out.voices, hasLength(1), reason: 'a game without a song is silence');
      });
    });

    test('a quick pass over games plays none of them', () {
      fakeAsync((async) {
        final out = FakeAudio();
        final decoded = <String>[];
        final music = ThemeMusic(
          out,
          decode: (path) async {
            decoded.add(path);
            return song(path);
          },
        );
        for (final name in ['a', 'b', 'c']) {
          music.play(game(name, music: '/$name.at9'));
          async.elapse(const Duration(milliseconds: 300));
        }
        expect(decoded, isEmpty);
        async.elapse(const Duration(milliseconds: 700));
        expect(decoded, ['/c.at9']);
      });
    });

    test('keeps the last three songs decoded and lets go of older ones', () {
      fakeAsync((async) {
        final out = FakeAudio();
        final decoded = <String>[];
        final music = ThemeMusic(
          out,
          decode: (path) async {
            decoded.add(path);
            return song(path);
          },
        );
        for (final name in ['a', 'b', 'c', 'd', 'a', 'd']) {
          music.play(game(name, music: '/$name.at9'));
          async.elapse(const Duration(seconds: 2));
        }
        expect(decoded, ['/a.at9', '/b.at9', '/c.at9', '/d.at9', '/a.at9']);
        expect(out.loaded.where((sound) => sound.released), hasLength(2));
      });
    });

    test('a theme\'s menu music plays when the game has no song; nothing at volume 0', () {
      fakeAsync((async) {
        final out = FakeAudio();
        final music = ThemeMusic(out, decode: (path) async => song(path));
        music.play(game('plain'), fallback: '/themes/calm/music.mp3');
        async.elapse(const Duration(seconds: 1));
        expect(out.voices.single.sound.name, '/themes/calm/music.mp3');
        expect(out.voices.single.loopStart, Duration.zero);
        music.volume = 0;
        music.play(null);
        music.play(game('other', music: '/o.at9'));
        async.elapse(const Duration(seconds: 3));
        expect(out.voices, hasLength(1));
      });
    });

    test('a song that cannot be decoded is silence', () {
      fakeAsync((async) {
        final out = FakeAudio();
        final music = ThemeMusic(out, decode: (path) async => null);
        music.play(game('broken', music: '/broken.at9'));
        async.elapse(const Duration(seconds: 3));
        expect(out.voices, isEmpty);
      });
    });
  });
}
