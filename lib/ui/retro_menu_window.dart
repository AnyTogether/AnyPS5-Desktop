import 'dart:async';

import 'package:flutter/widgets.dart';

import 'app_model.dart';
import 'components.dart';
import 'panels.dart';

class RetroMenuWindow extends StatefulWidget {
  const RetroMenuWindow({super.key, required this.model});

  final AppModel model;

  @override
  State<RetroMenuWindow> createState() => _RetroMenuWindowState();
}

class _RetroMenuWindowState extends State<RetroMenuWindow> {
  (int, Rect)? _requested;
  (int, Rect)? _sent;
  bool _clearPending = false;
  bool _clearing = false;

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final session = model.running;
    final gameMenu = model.overlay == Layer.quickMenu || model.overlay == Layer.closeGame;
    (int, Rect)? region;
    if (model.windowFullscreen && model.launcherInFront && gameMenu && session != null && session.$1.retro != null) {
      final categories = model.panelCategories();
      if (categories.isNotEmpty) {
        final view = View.of(context);
        final rows = categories[model.panelCategory.clamp(0, categories.length - 1)].rows.length;
        final size = PanelView.gameMenuSize(rows, LayoutScale.of(context) * view.devicePixelRatio);
        region = (
          session.$2.pid,
          Rect.fromCenter(center: view.physicalSize.center(Offset.zero), width: size.width, height: size.height),
        );
      }
    }
    _requested = region;
    if (_needsUpdate) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_updateRegion()));
    }
    return const SizedBox.shrink();
  }

  bool get _needsUpdate => _requested == null ? _clearPending && !_clearing : _sent != _requested;

  Future<void> _updateRegion() async {
    if (!mounted || !_needsUpdate) return;
    final next = _requested;
    _sent = next;
    if (next == null) {
      _clearing = true;
    } else {
      _clearPending = true;
    }
    final success = await widget.model.services.retroMenuRegion?.call(next?.$1, next?.$2);
    if (next == null) {
      _clearing = false;
      if (_sent == null && success == true) _clearPending = false;
      if (_sent != null && _requested == null) unawaited(_updateRegion());
    }
  }

  @override
  void dispose() {
    if (_clearPending) unawaited(widget.model.services.retroMenuRegion?.call(null, null));
    super.dispose();
  }
}
