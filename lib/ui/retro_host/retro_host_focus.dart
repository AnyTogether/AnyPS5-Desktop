import 'dart:async';

import 'package:flutter/widgets.dart';

/// Tells [onFocusChanged] whether the launcher's window has input focus: it has it while the app is
/// resumed, and loses it when the window is left, hidden or paused. The state the app is already in
/// is told after the first frame, and again when [onFocusChanged] changes.
class RetroHostFocus extends StatefulWidget {
  const RetroHostFocus({super.key, required this.onFocusChanged, required this.child});

  final Future<void> Function(bool focused) onFocusChanged;
  final Widget child;

  @override
  State<RetroHostFocus> createState() => _RetroHostFocusState();
}

class _RetroHostFocusState extends State<RetroHostFocus> {
  late final AppLifecycleListener _listener;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onStateChange: _tell);
    _tellCurrentLater();
  }

  @override
  void didUpdateWidget(RetroHostFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onFocusChanged != widget.onFocusChanged) _tellCurrentLater();
  }

  void _tellCurrentLater() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = WidgetsBinding.instance.lifecycleState;
      if (mounted && state != null) _tell(state);
    });
  }

  void _tell(AppLifecycleState state) => unawaited(widget.onFocusChanged(state == AppLifecycleState.resumed));

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
