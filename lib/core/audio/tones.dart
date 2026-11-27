import 'dart:math' as math;
import 'dart:typed_data';

import 'wav.dart';

/// The launcher's interface sounds: [bump] when a direction has nowhere to go, [hover] when the
/// pointer arrives on something.
enum Cue { move, select, back, unlocked, ring, bump, hover }

/// One sine of a cue: its frequency, when it starts and how long it lasts, in seconds.
typedef Partial = (double frequency, double start, double length);

/// Soft interface sounds, synthesized: a short tick for moving, a rising pair for selecting, a
/// falling one for going back, a rising three for something finished and two trills for a call.
/// Shaped after the PS5's own: low and round, nearly everything under 1 kHz, built on F4 (349 Hz)
/// with its octave below, a gentle rise and a soft fall, so no click and nothing sharp. The macOS
/// launcher's tones (Sounds.swift), sample for sample.
abstract final class Tones {
  static const sampleRate = 44100;

  /// How long a partial takes to reach its full level, in seconds: a rounded rise, not a tick.
  static const attack = 0.016;

  /// How long the end of a partial takes to fall to silence, so it never stops with a click.
  static const release = 0.012;

  /// Each cue's partials and how fast they die away. The notes are F4 (349 Hz), A4 (440 Hz) and C5
  /// (523 Hz); the quietest cue is an octave lower.
  static const recipes = <Cue, (List<Partial>, double)>{
    Cue.move: ([(349, 0.0, 0.11)], 26),
    Cue.select: ([(349, 0.0, 0.13), (523, 0.06, 0.2)], 15),
    Cue.back: ([(523, 0.0, 0.12), (349, 0.06, 0.2)], 15),
    Cue.unlocked: ([(349, 0.0, 0.2), (440, 0.12, 0.22), (523, 0.24, 0.6)], 6),
    // A friend calling: two soft trills.
    Cue.ring: ([(440, 0.0, 0.16), (523, 0.14, 0.16), (440, 0.28, 0.16), (523, 0.42, 0.26)], 5),
    // The end of a row: F3 and a fast decay, the quietest cue.
    Cue.bump: ([(175, 0.0, 0.11)], 38),
    // The pointer on something new: the move tick, about 3 dB lower.
    Cue.hover: ([(349, 0.0, 0.11)], 26),
  };

  /// How loud each cue is against the others (1 for the rest).
  static const gains = <Cue, double>{Cue.bump: 0.6, Cue.hover: 0.7};

  /// The cue as mono samples at [rate].
  static Float32List render(Cue cue, {int rate = sampleRate}) {
    final (partials, decay) = recipes[cue]!;
    final samples = synthesize(partials, decay, rate: rate);
    final gain = gains[cue] ?? 1;
    if (gain != 1) {
      for (var index = 0; index < samples.length; index++) {
        samples[index] *= gain;
      }
    }
    return samples;
  }

  /// Sine partials with a rounded [attack] and a soft [release], an exponential decay, the octave
  /// below that dies away a little slower (the body) and a quiet octave above that dies away
  /// faster; 20 ms of silence after the last one ends.
  static Float32List synthesize(List<Partial> partials, double decay, {int rate = sampleRate}) {
    final length = partials.isEmpty ? 0.1 : partials.map((partial) => partial.$2 + partial.$3).reduce(math.max);
    final frames = (rate * (length + 0.02)).floor();
    final samples = Float32List(frames);
    for (var frame = 0; frame < frames; frame++) {
      final time = frame / rate;
      var sample = 0.0;
      for (final (frequency, start, duration) in partials) {
        if (time < start || time >= start + duration) continue;
        final local = time - start;
        final rise = math.sin(math.pi / 2 * math.min(1.0, local / attack));
        final shape = rise * rise * math.min(1.0, (duration - local) / release);
        sample +=
            (math.sin(2 * math.pi * frequency * local) * math.exp(-local * decay) * 0.46 +
                math.sin(math.pi * frequency * local) * math.exp(-local * decay * 0.8) * 0.28 +
                math.sin(4 * math.pi * frequency * local) * math.exp(-local * decay * 1.8) * 0.08) *
            shape;
      }
      samples[frame] = sample;
    }
    return samples;
  }

  /// The cue as a stereo 16-bit WAV file, both sides the same, for the audio engine.
  static Uint8List wav(Cue cue) {
    final mono = render(cue);
    final stereo = Float32List(mono.length * 2);
    for (var frame = 0; frame < mono.length; frame++) {
      stereo[frame * 2] = mono[frame];
      stereo[frame * 2 + 1] = mono[frame];
    }
    return Wav.pcm16(stereo, channels: 2, sampleRate: sampleRate);
  }
}
