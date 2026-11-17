import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// A game picture on black, letterboxed to the display [aspect] the core reports. Draws nothing but
/// the black box while [image] has no picture.
class RetroFrameView extends StatelessWidget {
  const RetroFrameView({super.key, required this.image, required this.aspect, this.filterQuality = FilterQuality.none});

  final ValueListenable<ui.Image?> image;
  final double aspect;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xff000000),
      child: Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: ValueListenableBuilder<ui.Image?>(
            valueListenable: image,
            builder: (context, picture, _) => picture == null
                ? const SizedBox.expand()
                : RawImage(image: picture, fit: BoxFit.fill, filterQuality: filterQuality),
          ),
        ),
      ),
    );
  }
}
