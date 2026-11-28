import 'dart:io';
import 'dart:typed_data';

import 'package:anyps5_desktop/core/artwork_cache.dart';
import 'package:anyps5_desktop/core/screenshots.dart' show PngEncoder;
import 'package:anyps5_desktop/ui/components.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A game's background and the lighter copy it is drawn from: nothing but the image may sit
/// between the drift's scale and the picture once it is shown, or the drift moves in
/// whole-pixel steps instead of smoothly.
void main() {
  late Directory temp;
  late File picture;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('anyps5-artwork-image');
    picture = File(p.join(temp.path, 'pic0.png'))..writeAsBytesSync(PngEncoder.rgba(4, 2, Uint8List(4 * 2 * 4)));
    ArtworkCache.instance
      ..folder = p.join(temp.path, 'cache')
      ..clearForTest();
    ArtworkImage.readSynchronously = true;
  });

  tearDown(() {
    ArtworkImage.readSynchronously = false;
    ArtworkCache.instance
      ..folder = null
      ..clearForTest();
    temp.deleteSync(recursive: true);
  });

  Widget background() => Directionality(
    textDirection: TextDirection.ltr,
    child: ArtworkImage(path: picture.path, background: true),
  );

  testWidgets('a background whose copy is ready is drawn by the image alone', (tester) async {
    // Avoid the lighten isolate: mark the path ready as the real cache would after a copy.
    ArtworkCache.instance.markReadyForTest(picture.path, picture.path);
    await tester.pumpWidget(background());
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(Opacity), findsNothing);
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
  });

  testWidgets('a background that waited for its copy fades in, then is the image alone again', (tester) async {
    await tester.pumpWidget(background());
    expect(find.byType(Image), findsNothing);

    // Copy becomes ready after the first build (the waiting path).
    ArtworkCache.instance.markReadyForTest(picture.path, picture.path);
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(Opacity), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(Opacity), findsNothing);
  });
}
