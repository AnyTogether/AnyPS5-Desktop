import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('probe: a golden with no file yet', (tester) async {
    await tester.pumpWidget(const ColoredBox(color: Color(0xFF123456)));
    await expectLater(find.byType(ColoredBox), matchesGoldenFile('goldens/probe_new.png'));
  });
}
