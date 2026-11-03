import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liquid_glass_widgets/features/auth/managed_dataset_access_workspace.dart';

void main() {
  testWidgets('Branch Data & Access skeleton adapts across supported widths',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 900);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ManagedDatasetAccessSkeleton(),
          ),
        ),
      ),
    );

    for (final width in <double>[768, 1024, 1366, 360]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pump();

      expect(
        find.byType(ManagedDatasetAccessSkeleton),
        findsOneWidget,
        reason: 'The dataset skeleton should render at $width logical pixels.',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'The dataset skeleton must not overflow at $width logical pixels.',
      );
    }
  });
}
