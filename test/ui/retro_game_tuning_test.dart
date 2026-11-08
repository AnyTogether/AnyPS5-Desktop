import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/ui/retro_game_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

const scale = 'swanstation_GPU_ResolutionScale';
const filter = 'swanstation_GPU_TextureFilter';

EmbeddedOption option(List<String> values, int selected) =>
    (values: values, labels: values, title: '', restart: false, selected: selected);

Map<String, Object> telemetry(int millis, int frames, {int slowFrames = 0}) => {
  'clockMs': millis,
  'frames': frames,
  'steps': frames,
  'audioFrames': millis * 48,
  'droppedAudioFrames': 0,
  'frameIntervals': [0, 0, frames - slowFrames, 0, 0, 0, slowFrames, 0, 0, 0, 0, 0, 0],
  'targetFps': 60.0,
  'audioRate': 48000.0,
};

void main() {
  test('records paired gameplay samples, restores the baseline before review and applies both values', () async {
    final options = {
      scale: option(['1', '2', '3'], 0),
      filter: option(['Nearest', 'BilinearBinAlpha'], 0),
    };
    final persisted = <Map<String, String>>[];
    var saveFails = true;
    final writes = <Map<String, String>>[];
    final tuning = RetroGameTuning(
      platform: RetroPlatform.ps1,
      options: options,
      ready: () => true,
      writeOptions: (expected, values) async {
        for (final entry in expected.entries) {
          final selected = options[entry.key]!;
          if (selected.values[selected.selected] != entry.value) return false;
        }
        writes.add(values);
        for (final entry in values.entries) {
          final previous = options[entry.key]!;
          options[entry.key] = option(previous.values, previous.values.indexOf(entry.value));
        }
        return true;
      },
      persist: (before, values, {required undo}) {
        if (saveFails) throw const FormatException('Could not save preferences');
        persisted.add(values);
      },
      changed: () {},
    );

    await tuning.observe(telemetry(0, 0), playing: false);
    expect(await tuning.startBaseline(), isTrue);
    await tuning.observe(telemetry(500, 30), playing: false);
    await tuning.observe(telemetry(1000, 60), playing: true);
    await tuning.observe(telemetry(3100, 186), playing: true);
    await tuning.observe(telemetry(13100, 786), playing: true);
    expect(tuning.baseline?.videoFps, 60);
    expect(writes, isEmpty);

    expect(await tuning.startCandidate(), isTrue);
    await tuning.observe(telemetry(14000, 840), playing: true);
    await tuning.observe(telemetry(16100, 966), playing: true);
    await tuning.observe(telemetry(26100, 1566), playing: true);
    expect(tuning.candidate?.videoFps, 60);
    expect(writes, [
      {scale: '2', filter: 'BilinearBinAlpha'},
      {scale: '1', filter: 'Nearest'},
    ]);
    expect(persisted, isEmpty);
    expect(tuning.canApply, isTrue);
    await tuning.apply();
    expect(options[scale]?.selected, 0);
    expect(options[filter]?.selected, 0);
    expect(persisted, isEmpty);
    expect(tuning.status, contains('could not be saved'));
    saveFails = false;
    await tuning.apply();
    expect(persisted, [
      {scale: '2', filter: 'BilinearBinAlpha'},
    ]);
    expect(tuning.canUndo, isTrue);
    await tuning.undo();
    expect(persisted.last, {scale: '1', filter: 'Nearest'});
  });

  test('an interrupted sample cannot produce a recommendation', () async {
    final tuning = RetroGameTuning(
      platform: RetroPlatform.ps2,
      options: {
        'pcsx2_anisotropic_filtering': option(['disabled', '2x'], 0),
        'pcsx2_trilinear_filtering': option(['Automatic', 'Trilinear (PS2)'], 0),
      },
      ready: () => true,
      writeOptions: (expected, values) async => true,
      persist: (before, values, {required undo}) => fail('Interrupted settings must not be persisted'),
      changed: () {},
    );
    await tuning.observe(telemetry(0, 0), playing: false);
    expect(await tuning.startBaseline(), isTrue);
    await tuning.observe(telemetry(1000, 60), playing: true);
    await tuning.observe(telemetry(3200, 192), playing: true);
    await tuning.interrupt();
    await tuning.observe(telemetry(4000, 240), playing: true);
    expect(tuning.baseline, isNull);
    expect(tuning.canStartCandidate, isFalse);
    expect(tuning.canApply, isFalse);
    expect(tuning.status, contains('interrupted'));
  });

  test('PS2 tuner sends the exact core resolution value together with filtering', () async {
    const resolution = 'pcsx2_upscale_multiplier';
    const anisotropy = 'pcsx2_anisotropic_filtering';
    Map<String, String>? requested;
    final tuning = RetroGameTuning(
      platform: RetroPlatform.ps2,
      options: {
        resolution: option(['1x (Native)', '2x', '4x'], 0),
        anisotropy: option(['disabled', '4x'], 0),
      },
      ready: () => true,
      writeOptions: (expected, values) async {
        expect(expected, {resolution: '1x (Native)', anisotropy: 'disabled'});
        requested = values;
        return true;
      },
      persist: (_, _, {required undo}) => fail('The temporary candidate must not be saved'),
      changed: () {},
    );
    await tuning.observe(telemetry(0, 0), playing: false);
    expect(await tuning.startBaseline(), isTrue);
    await tuning.observe(telemetry(1000, 60), playing: true);
    await tuning.observe(telemetry(3100, 186), playing: true);
    await tuning.observe(telemetry(13100, 786), playing: true);
    expect(await tuning.startCandidate(), isTrue);
    expect(requested, {resolution: '2x', anisotropy: '4x'});
  });

  test('comparison rejects stutter or a substantial audio regression', () {
    final baseline = const RetroTuningSample(
      videoFps: 30,
      stepRatio: 1,
      frameTime95: 35,
      audioRatio: 0.99,
      droppedAudio: 0,
    );
    final slow = const RetroTuningSample(
      videoFps: 30,
      stepRatio: 1,
      frameTime95: 75,
      audioRatio: 0.99,
      droppedAudio: 0,
    );
    final audio = const RetroTuningSample(
      videoFps: 30,
      stepRatio: 1,
      frameTime95: 35,
      audioRatio: 0.8,
      droppedAudio: 0,
    );
    expect(slow.holdsBaseline(baseline), isFalse);
    expect(audio.holdsBaseline(baseline), isFalse);
  });
}
