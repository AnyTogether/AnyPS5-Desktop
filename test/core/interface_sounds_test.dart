import 'dart:math' as math;
import 'dart:typed_data';

import 'package:anyps5_desktop/core/audio/interface_sounds.dart';
import 'package:anyps5_desktop/core/audio/tones.dart';
import 'package:anyps5_desktop/core/audio/wav.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_audio.dart';

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
  group('Tones', () {
    test('every cue is as long as its partials and 20 ms more', () {
      expect(
        {for (final cue in Cue.values) cue: Tones.render(cue).length},
        {
          Cue.move: 5733,
          Cue.select: 12348,
          Cue.back: 12348,
          Cue.unlocked: 37926,
          Cue.ring: 30869,
          Cue.bump: 5733,
          Cue.hover: 5733,
        },
      );
    });

    test('the sample values: F4 with its octave below and above, a rounded 16 ms rise, a fast decay', () {
      final move = Tones.render(Cue.move);
      expect(move[0], 0);
      // 10 ms in: 349 Hz, the octave below it (the body) and the octave above it (a trace).
      const time = 441 / 44100;
      final rise = math.sin(math.pi / 2 * time / 0.016);
      final expected =
          (math.sin(2 * math.pi * 349 * time) * math.exp(-time * 26) * 0.46 +
              math.sin(math.pi * 349 * time) * math.exp(-time * 26 * 0.8) * 0.28 +
              math.sin(4 * math.pi * 349 * time) * math.exp(-time * 26 * 1.8) * 0.08) *
          rise *
          rise;
      expect(move[441], closeTo(expected, 1e-6));
    });

    test('no cue clips, each rises within its attack, dies away and ends in silence', () {
      for (final cue in Cue.values) {
        final samples = Tones.render(cue);
        final peak = samples.map((sample) => sample.abs()).reduce(math.max);
        expect(peak, lessThan(1), reason: '$cue');
        expect(peak, greaterThan(0.2), reason: '$cue');
        // The first 16 ms stay under the attack's line: a rounded rise, no click.
        const frames = 705;
        for (var frame = 0; frame < frames; frame++) {
          final rise = math.sin(math.pi / 2 * frame / frames);
          expect(
            samples[frame].abs(),
            lessThanOrEqualTo(0.82 * (Tones.gains[cue] ?? 1) * rise * rise + 1e-6),
            reason: '$cue at $frame',
          );
        }
        // The last 20 ms are silent.
        final tail = samples.sublist(samples.length - 880);
        expect(tail.every((sample) => sample == 0), isTrue, reason: '$cue');
        // Each cue is quieter in its second half than in its first.
        final half = samples.length ~/ 2;
        expect(rms(samples.sublist(half)), lessThan(rms(samples.sublist(0, half)) * 0.9), reason: '$cue');
      }
    });

    test('soft and deep like the PS5: almost all of every cue is under 1 kHz, none above 2 kHz', () {
      for (final cue in Cue.values) {
        final samples = Tones.render(cue);
        var total = 0.0;
        var low = 0.0;
        var high = 0.0;
        // A direct Fourier sum over the bins from 50 Hz to 4 kHz in 25 Hz steps.
        for (var frequency = 50.0; frequency <= 4000; frequency += 25) {
          var re = 0.0;
          var im = 0.0;
          for (var frame = 0; frame < samples.length; frame++) {
            final angle = 2 * math.pi * frequency * frame / Tones.sampleRate;
            re += samples[frame] * math.cos(angle);
            im += samples[frame] * math.sin(angle);
          }
          final power = re * re + im * im;
          total += power;
          if (frequency < 1000) low += power;
          if (frequency >= 2000) high += power;
        }
        expect(low / total, greaterThan(0.97), reason: '$cue');
        expect(high / total, lessThan(0.001), reason: '$cue');
      }
    });

    test('a cue as a WAV file: stereo 16-bit, both sides the same', () {
      final wav = Tones.wav(Cue.select);
      final bytes = ByteData.sublistView(wav);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(bytes.getUint16(22, Endian.little), 2);
      expect(bytes.getUint32(24, Endian.little), 44100);
      expect(bytes.getUint16(34, Endian.little), 16);
      expect(bytes.getUint32(40, Endian.little), 12348 * 4);
      expect(wav.length, 44 + 12348 * 4);
      for (var frame = 0; frame < 12348; frame += 97) {
        expect(bytes.getInt16(44 + frame * 4, Endian.little), bytes.getInt16(46 + frame * 4, Endian.little));
      }
    });
  });

  group('Wav', () {
    test('holds samples past full scale and writes a part of the frames', () {
      final samples = Float32List.fromList([0, 0, 0.5, -0.5, 2, -2, 1, -1]);
      final wav = ByteData.sublistView(Wav.pcm16(samples, channels: 2, sampleRate: 48000, start: 1, end: 3));
      expect(wav.lengthInBytes, 44 + 2 * 4);
      expect(wav.getUint32(4, Endian.little), 36 + 8);
      expect(wav.getUint32(28, Endian.little), 48000 * 4);
      expect([for (var at = 44; at < 52; at += 2) wav.getInt16(at, Endian.little)], [16384, -16384, 32767, -32767]);
    });
  });

  group('InterfaceSounds', () {
    test('loads the seven cues once and plays them softly under the volume chosen', () async {
      final out = FakeAudio();
      final sounds = InterfaceSounds(out);
      sounds.play(Cue.move);
      expect(out.voices, isEmpty, reason: 'nothing before the output is open');
      await sounds.start();
      await sounds.start();
      expect(out.loaded.map((sound) => sound.name), [
        'anyps5-move.wav',
        'anyps5-select.wav',
        'anyps5-back.wav',
        'anyps5-unlocked.wav',
        'anyps5-ring.wav',
        'anyps5-bump.wav',
        'anyps5-hover.wav',
      ]);
      sounds.play(Cue.select);
      expect(out.cues, ['select']);
      expect(out.voices.single.volume, closeTo(0.32, 1e-9));
      sounds.volume = 0.5;
      await Future<void>.value();
      sounds.play(Cue.back);
      expect(out.voices.last.volume, closeTo(0.16, 1e-9));
      sounds.enabled = false;
      sounds.play(Cue.move);
      expect(out.cues, ['select', 'back']);
    });

    test('every cue asked for is counted and told, sounds on or off (the pulse that goes with it)', () async {
      final sounds = InterfaceSounds(FakeAudio());
      final told = <Cue>[];
      sounds.onCue = told.add;
      sounds.enabled = false;
      sounds.play(Cue.select);
      sounds.play(Cue.bump);
      expect(sounds.requests, 2);
      expect(told, [Cue.select, Cue.bump]);
    });

    test('the bump is the quietest cue and the hover tick is the move tick, softer', () {
      double peak(Cue cue) => Tones.render(cue).map((sample) => sample.abs()).reduce(math.max);
      for (final cue in Cue.values.where((cue) => cue != Cue.bump)) {
        expect(peak(Cue.bump), lessThan(peak(cue)), reason: '$cue');
      }
      expect(peak(Cue.hover), closeTo(peak(Cue.move) * 0.7, 1e-6));
    });

    test('four voices in turn: a fifth sound stops the first', () async {
      final out = FakeAudio();
      final sounds = InterfaceSounds(out);
      await sounds.start();
      for (var index = 0; index < 5; index++) {
        sounds.play(Cue.move);
        await Future<void>.value();
      }
      expect(out.voices.map((voice) => voice.stopped), [true, false, false, false, false]);
    });

    test('the same cue twice in one step plays once; muted, none plays', () async {
      final out = FakeAudio();
      final sounds = InterfaceSounds(out);
      await sounds.start();
      sounds
        ..play(Cue.select)
        ..play(Cue.select)
        ..play(Cue.back);
      expect(out.cues, ['select', 'back']);
      await Future<void>.value();
      sounds.play(Cue.select);
      expect(out.cues, ['select', 'back', 'select']);
      await Future<void>.value();
      sounds
        ..muted = true
        ..play(Cue.move);
      expect(out.cues, hasLength(3));
    });

    test('without an output it stays quiet', () async {
      final out = FakeAudio(works: false);
      final sounds = InterfaceSounds(out);
      await sounds.start();
      sounds.play(Cue.select);
      expect(out.voices, isEmpty);
    });
  });
}
