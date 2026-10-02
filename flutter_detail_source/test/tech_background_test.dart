import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/app_colors.dart';
import 'package:liquid_glass_widgets/tech_background.dart';

void main() {
  testWidgets('shared background uses the historical animated navy treatment', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: TechAnimatedBackground()),
    );

    expect(kAppBackgroundColor, const Color(0xFF22D3EE));
    expect(find.byType(DecoratedBox), findsWidgets);
    expect(find.byType(CustomPaint), findsAtLeastNWidgets(1));
    expect(find.byType(ColoredBox), findsNothing);
  });
}
