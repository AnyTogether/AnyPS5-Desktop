import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/game_library.dart';
import '../core/retro_optimizer.dart';
import '../core/retro_optimizer_undo.dart';
import '../core/retro_settings.dart';
import 'app_model.dart';

class RetroQuickOptimize {
  RetroQuickOptimize(this.app, this.refresh);

  final AppModel app;
  final void Function() refresh;
  final _modes = <RetroPlatform, RetroOptimizationMode>{};
  final _hardware = <RetroPlatform, RetroHardware?>{};
  final _checking = <RetroPlatform>{};
  late final _undo = RetroOptimizerUndo(Directory(p.join(app.paths.config, 'RetroOptimize')));

  PanelCategory category(
    RetroPlatform platform,
    RetroSettings settings, {
    required void Function(void Function()) save,
  }) {
    final id = 'retro-${platform.name}-optimize';
    final mode = _mode(platform);
    final checking = _checking.contains(platform);
    final hardware = _hardware[platform];
    final profile = _profile(platform, settings);
    final recommendation = _recommend(platform, mode, profile, hardware);
    final current = profile?.scale ?? (platform == RetroPlatform.ps1 ? '0' : '1');
    final currentLabel = current == '0' ? 'Auto' : '$current×';
    final alreadyApplied = double.tryParse(current) == recommendation?.scale;
    return PanelCategory(
      id: id,
      title: '${platform.emulator} · Quick Optimize',
      rows: [
        PanelRow(
          id: '$id-mode',
          title: 'Optimization profile',
          detail: 'Choose how much internal resolution to trade for graphics headroom.',
          kind: ChoiceRow(const ['Performance', 'Balanced', 'Quality'], mode.index, (index) {
            _modes[platform] = RetroOptimizationMode.values[index];
            refresh();
          }),
        ),
        PanelRow(
          id: '$id-preview',
          title: checking ? 'Detecting your PC' : 'Preview recommended settings',
          detail: 'Reads your graphics adapter and the display showing AnyPS5.',
          kind: checking ? const InfoRow('Please wait') : ActionRow(() => unawaited(_detect(platform))),
        ),
        if (recommendation != null)
          PanelRow(
            id: '$id-summary',
            title: alreadyApplied
                ? 'Internal Resolution is ${recommendation.scale}×'
                : 'Internal Resolution · $currentLabel → ${recommendation.scale}×',
            detail:
                '${recommendation.adapter.name} · '
                '${(recommendation.adapter.dedicatedBytes / (1 << 30)).toStringAsFixed(1)} GiB · '
                '${recommendation.displayHeight}p display',
            kind: const InfoRow('Suggested starting point'),
          )
        else if (_hardware.containsKey(platform) && !checking)
          PanelRow(
            id: '$id-unavailable',
            title: 'Hardware recommendation unavailable',
            detail: 'Quick Optimize needs an identifiable graphics adapter, a display and a hardware renderer.',
            kind: const InfoRow('Use manual graphics settings'),
          ),
        if (recommendation != null && !alreadyApplied && !checking)
          PanelRow(
            id: '$id-apply',
            title: 'Apply recommendation',
            detail: 'Applies to this emulator on its next launch.',
            kind: ActionRow(() => unawaited(_apply(platform, mode, settings, recommendation, save))),
          ),
        if (!checking && _undo.canUndo(platform: platform, settings: settings))
          PanelRow(
            id: '$id-undo',
            title: 'Undo Quick Optimize',
            detail: 'Restore the previous internal resolution.',
            kind: ActionRow(() => save(() => _undo.undo(platform: platform, settings: settings))),
          ),
      ],
    );
  }

  RetroOptimizationMode _mode(RetroPlatform platform) => _modes[platform] ?? RetroOptimizationMode.balanced;

  ({String? renderer, String? adapter, String? scale})? _profile(RetroPlatform platform, RetroSettings settings) {
    final (section, scaleKey) = platform == RetroPlatform.ps1
        ? ('GPU', 'ResolutionScale')
        : ('EmuCore/GS', 'upscale_multiplier');
    final values = <String, String>{};
    final options = settings.options.where((option) => option.section.toLowerCase() == section.toLowerCase()).toList();
    for (final key in ['Renderer', 'Adapter', scaleKey]) {
      final matches = options.where((option) => option.key.toLowerCase() == key.toLowerCase()).toList();
      if (matches.length > 1) return null;
      if (matches.singleOrNull case final RetroOption option) {
        if (option.section != section || option.key != key) return null;
        values[key] = option.value;
      }
    }
    return (renderer: values['Renderer'], adapter: values['Adapter'], scale: values[scaleKey]);
  }

  RetroOptimizationRecommendation? _recommend(
    RetroPlatform platform,
    RetroOptimizationMode mode,
    ({String? renderer, String? adapter, String? scale})? profile,
    RetroHardware? hardware,
  ) {
    if (hardware == null || profile == null) return null;
    return RetroOptimizer.recommend(
      platform: platform,
      mode: mode,
      hardware: hardware,
      renderer: profile.renderer,
      adapter: profile.adapter,
    );
  }

  Future<RetroHardware?> _readHardware() async {
    try {
      return await app.services.retroHardware?.call();
    } on Object {
      return null;
    }
  }

  Future<void> _detect(RetroPlatform platform) async {
    if (!_checking.add(platform)) return;
    refresh();
    try {
      _hardware[platform] = await _readHardware();
    } finally {
      _checking.remove(platform);
      refresh();
    }
  }

  Future<void> _apply(
    RetroPlatform platform,
    RetroOptimizationMode mode,
    RetroSettings settings,
    RetroOptimizationRecommendation preview,
    void Function(void Function()) save,
  ) async {
    if (!_checking.add(platform)) return;
    refresh();
    try {
      final hardware = await _readHardware();
      _hardware[platform] = hardware;
      final current = _recommend(platform, mode, _profile(platform, settings), hardware);
      final program = app.retroSettings.program(platform);
      if (current == null ||
          current.scale != preview.scale ||
          current.displayHeight != preview.displayHeight ||
          current.adapter.name != preview.adapter.name ||
          current.adapter.dedicatedBytes != preview.adapter.dedicatedBytes ||
          _mode(platform) != mode ||
          program == null ||
          !p.equals(RetroSettings.configFile(program, platform).absolute.path, settings.file.absolute.path)) {
        app.show('The display or emulator selection changed. Review the updated preview.');
        return;
      }
      save(() => _undo.apply(platform: platform, settings: settings, recommendation: current));
    } finally {
      _checking.remove(platform);
      refresh();
    }
  }
}
