import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/test_motion_mode.dart';

void main() {
  test('test mode is opt-in through the browser URL', () {
    expect(
      isDetailAnalysisTestMode(Uri.parse('http://localhost/ui/')),
      isFalse,
    );
    expect(
      isDetailAnalysisTestMode(Uri.parse('http://localhost/ui/?testMode=1')),
      isTrue,
    );
    expect(
      isDetailAnalysisTestMode(Uri.parse('http://localhost/ui/?testMode=true')),
      isFalse,
    );
  });

  testWidgets('test mode disables motion without changing normal mode', (
    tester,
  ) async {
    Future<void> pumpMode(bool enabled) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => applyDetailAnalysisTestMotionMode(
            context,
            enabled: enabled,
            child: child ?? const SizedBox.shrink(),
          ),
          home: Builder(
            builder: (context) => Text(
              '${MediaQuery.disableAnimationsOf(context)}|'
              '${GlassAccessibilityData.of(context).reduceMotion}',
            ),
          ),
        ),
      );
    }

    await pumpMode(false);
    expect(find.text('false|false'), findsOneWidget);

    await pumpMode(true);
    expect(find.text('true|true'), findsOneWidget);
  });
}
