import 'dart:math' as math;

import 'game_library.dart';

class RetroAdapter {
  const RetroAdapter({required this.name, required this.dedicatedBytes});

  final String name;
  final int dedicatedBytes;
}

class RetroHardware {
  const RetroHardware({required this.displayHeight, required this.adapters});

  final int displayHeight;
  final List<RetroAdapter> adapters;
}

enum RetroOptimizationMode { performance, balanced, quality }

class RetroOptimizationRecommendation {
  const RetroOptimizationRecommendation({
    required this.section,
    required this.key,
    required this.scale,
    required this.adapter,
    required this.displayHeight,
  });

  final String section;
  final String key;
  final int scale;
  final RetroAdapter adapter;
  final int displayHeight;
}

abstract final class RetroOptimizer {
  static const _gib = 1 << 30;

  static RetroOptimizationRecommendation? recommend({
    required RetroPlatform platform,
    required RetroOptimizationMode mode,
    required RetroHardware hardware,
    required String? renderer,
    required String? adapter,
  }) {
    if (hardware.displayHeight <= 0 || !_canUpscale(platform, renderer)) return null;
    final selected = _selectAdapter(hardware.adapters, adapter);
    if (selected == null) return null;

    final (section, key, nativeHeight) = switch (platform) {
      RetroPlatform.ps1 => ('GPU', 'ResolutionScale', 240),
      RetroPlatform.ps2 => ('EmuCore/GS', 'upscale_multiplier', 360),
      RetroPlatform.ps3 => throw StateError('PS3 uses embedded graphics options.'),
    };
    final modeCap = switch (mode) {
      RetroOptimizationMode.performance => 1,
      RetroOptimizationMode.balanced => 4,
      RetroOptimizationMode.quality => 6,
    };
    final displayScale = (hardware.displayHeight - 1) ~/ nativeHeight + 1;
    final scale = math.min(displayScale, math.min(modeCap, _memoryCap(selected.dedicatedBytes)));
    return RetroOptimizationRecommendation(
      section: section,
      key: key,
      scale: scale,
      adapter: selected,
      displayHeight: hardware.displayHeight,
    );
  }

  static bool _canUpscale(RetroPlatform platform, String? renderer) {
    if (platform == RetroPlatform.ps3) return false;
    final value = renderer?.trim().toLowerCase() ?? '';
    if (value.isEmpty) return true;
    return switch (platform) {
      RetroPlatform.ps1 => const {'automatic', 'd3d11', 'd3d12', 'metal', 'vulkan', 'opengl'}.contains(value),
      RetroPlatform.ps2 => const {-1, 3, 12, 14, 15, 17}.contains(int.tryParse(value)),
      RetroPlatform.ps3 => false,
    };
  }

  static bool _usable(RetroAdapter adapter) => adapter.name.trim().isNotEmpty && adapter.dedicatedBytes > 0;

  static RetroAdapter? _selectAdapter(List<RetroAdapter> adapters, String? configured) {
    if (configured != null && configured.trim().isNotEmpty) {
      final name = configured.toLowerCase();
      final exact = adapters.where((adapter) => adapter.name.toLowerCase() == name).toList();
      return exact.length == 1 && _usable(exact.single) ? exact.single : null;
    }

    final usable = adapters.where(_usable).toList();
    if (usable.length == 1) return usable.single;
    final discrete = usable.where((adapter) => adapter.dedicatedBytes >= 2 * _gib).toList();
    return discrete.length == 1 ? discrete.single : null;
  }

  static int _memoryCap(int dedicatedBytes) {
    if (dedicatedBytes >= 12 * _gib) return 6;
    if (dedicatedBytes >= 8 * _gib) return 4;
    if (dedicatedBytes >= 4 * _gib) return 3;
    if (dedicatedBytes >= 2 * _gib) return 2;
    return 1;
  }
}
