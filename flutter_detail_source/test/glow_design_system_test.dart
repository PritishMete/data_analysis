import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glow_design_system.dart';
import '../lib/widgets/containers/glass_container.dart';

void main() {
  test('glow tokens match the existing top-tab reference geometry', () {
    expect(GlowDesignSystem.blurRadius, 32);
    expect(GlowDesignSystem.spreadRadius, 8);
    expect(GlowDesignSystem.activeOpacity, 0.6);
    expect(GlowDesignSystem.ambientOpacity, 0.12);
  });

  testWidgets('ambient container glow stays outside the glass surface', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(24),
            child: GlassContainer(
              child: SizedBox(width: 120, height: 60),
            ),
          ),
        ),
      ),
    );

    final decorated = tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
    final withShadow = decorated.where((widget) {
      final decoration = widget.decoration;
      return decoration is BoxDecoration && decoration.boxShadow?.isNotEmpty == true;
    }).toList();

    expect(withShadow, isNotEmpty);
    final decoration = withShadow.first.decoration as BoxDecoration;
    final shadow = decoration.boxShadow!.first;
    expect(shadow.blurRadius, GlowDesignSystem.blurRadius);
    expect(shadow.spreadRadius, 0);
    expect(tester.takeException(), isNull);
  });
}
