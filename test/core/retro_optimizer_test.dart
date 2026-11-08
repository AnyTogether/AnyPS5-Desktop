import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/retro_optimizer.dart';
import 'package:test/test.dart';

const _gib = 1 << 30;
const _discrete = RetroAdapter(name: 'GeForce RTX', dedicatedBytes: 16 * _gib);
const _integrated = RetroAdapter(name: 'Integrated Graphics', dedicatedBytes: _gib ~/ 2);

RetroOptimizationRecommendation? _recommend({
  RetroPlatform platform = RetroPlatform.ps2,
  RetroOptimizationMode mode = RetroOptimizationMode.balanced,
  int height = 1440,
  List<RetroAdapter> adapters = const [_integrated, _discrete],
  String? renderer,
  String? adapter,
}) => RetroOptimizer.recommend(
  platform: platform,
  mode: mode,
  hardware: RetroHardware(displayHeight: height, adapters: adapters),
  renderer: renderer,
  adapter: adapter,
);

void main() {
  test('balanced uses the unique discrete adapter and writes the platform’s native scale key', () {
    final ps2 = _recommend()!;
    expect(ps2.adapter, same(_discrete));
    expect(ps2.displayHeight, 1440);
    expect((ps2.section, ps2.key, ps2.scale), ('EmuCore/GS', 'upscale_multiplier', 4));

    final ps1 = _recommend(platform: RetroPlatform.ps1, height: 720)!;
    expect((ps1.section, ps1.key, ps1.scale), ('GPU', 'ResolutionScale', 3));
  });

  test('an explicitly selected adapter wins when its name matches exactly, ignoring case', () {
    expect(_recommend(adapter: 'integrated graphics')!.adapter, same(_integrated));
    expect(_recommend(adapter: 'integrated graphics')!.scale, 1);
    expect(_recommend(adapter: 'GeForce'), isNull);
    expect(
      _recommend(
        adapter: 'geforce rtx',
        adapters: const [
          _discrete,
          RetroAdapter(name: 'GEFORCE RTX', dedicatedBytes: 8 * _gib),
        ],
      ),
      isNull,
    );
  });

  test('ambiguous adapters and missing hardware information withhold a recommendation', () {
    expect(
      _recommend(
        adapters: const [
          _discrete,
          RetroAdapter(name: 'Second discrete GPU', dedicatedBytes: 4 * _gib),
        ],
      ),
      isNull,
    );
    expect(_recommend(adapters: const [RetroAdapter(name: 'Unknown memory', dedicatedBytes: 0)]), isNull);
    expect(_recommend(adapters: const []), isNull);
    expect(_recommend(height: 0), isNull);
    expect(_recommend(adapters: const [_integrated])!.adapter, same(_integrated));
  });

  test('performance uses native and quality respects display and memory caps', () {
    expect(_recommend(mode: RetroOptimizationMode.performance)!.scale, 1);
    expect(_recommend(mode: RetroOptimizationMode.quality, height: 1080)!.scale, 3);
    expect(_recommend(mode: RetroOptimizationMode.quality, height: 2160)!.scale, 6);
    expect(_recommend(height: 2160)!.scale, 4);
    for (final (memory, scale) in [(2 * _gib - 1, 1), (2 * _gib, 2), (4 * _gib, 3), (8 * _gib, 4), (12 * _gib, 6)]) {
      expect(
        _recommend(
          mode: RetroOptimizationMode.quality,
          height: 2160,
          adapters: [RetroAdapter(name: 'GPU', dedicatedBytes: memory)],
        )!.scale,
        scale,
        reason: '$memory dedicated bytes',
      );
    }
  });

  test('software, null and unknown renderers withhold a recommendation', () {
    expect(_recommend(platform: RetroPlatform.ps1, renderer: 'software'), isNull);
    expect(_recommend(platform: RetroPlatform.ps1, renderer: 'Vulkan')!.scale, 4);
    expect(_recommend(renderer: '13'), isNull);
    expect(_recommend(renderer: '11'), isNull);
    expect(_recommend(renderer: 'invalid'), isNull);
    expect(_recommend(renderer: '14')!.scale, 4);
  });
}
