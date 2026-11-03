import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/features/auth/managed_dataset_access_workspace.dart';

void main() {
  testWidgets('Branch Data & Access skeleton adapts across supported widths',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    for (final width in <double>[360, 768, 1024, 1366]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ManagedDatasetAccessSkeleton(),
            ),
          ),
        ),
      );

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
