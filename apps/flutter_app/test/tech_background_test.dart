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
    final historicalGradient = tester.widgetList<DecoratedBox>(
      find.byType(DecoratedBox),
    ).any((widget) {
      final decoration = widget.decoration;
      if (decoration is! BoxDecoration) return false;
      final gradient = decoration.gradient;
      return gradient is LinearGradient &&
          gradient.colors.length == 3 &&
          gradient.colors[0] == const Color(0xFF080B14) &&
          gradient.colors[1] == const Color(0xFF0F111A) &&
          gradient.colors[2] == const Color(0xFF0A0E1A);
    });
    expect(historicalGradient, isTrue);
  });
}
