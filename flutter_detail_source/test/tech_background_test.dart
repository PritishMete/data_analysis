import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/app_colors.dart';
import 'package:liquid_glass_widgets/tech_background.dart';

void main() {
  testWidgets('shared background is an exact solid ScanButton cyan', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: TechAnimatedBackground()),
    );

    expect(kAppBackgroundColor, const Color(0xFF22D3EE));
    final background = tester.widget<ColoredBox>(find.byType(ColoredBox));
    expect(background.color, kAppBackgroundColor);
  });
}
