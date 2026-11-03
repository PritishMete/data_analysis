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

  testWidgets('read-only skeleton never suggests management actions',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ManagedDatasetAccessSkeleton(
              readOnly: true,
              capabilities: <String>{'dataset.view_original'},
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('dataset-upload-skeleton')), findsNothing);
    expect(find.byKey(const ValueKey('dataset-proposal-skeleton')), findsNothing);
    expect(find.byKey(const ValueKey('dataset-access-skeleton')), findsNothing);
  });

  testWidgets('Branch Head skeleton reflects authorized dataset workflows',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ManagedDatasetAccessSkeleton(
              capabilities: <String>{
                'dataset.upload.direct',
                'dataset.proposal.review',
                'dataset.copy_requests.review',
                'dataset.upload_grants.manage',
              },
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('dataset-upload-skeleton')), findsOneWidget);
    expect(find.byKey(const ValueKey('dataset-proposal-skeleton')), findsOneWidget);
    expect(find.byKey(const ValueKey('dataset-access-skeleton')), findsOneWidget);
  });

  testWidgets('Manager skeleton shows proposals but not direct original upload',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ManagedDatasetAccessSkeleton(
              capabilities: <String>{
                'dataset.upload',
                'dataset.proposal.submit',
                'dataset.copy.request',
              },
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('dataset-upload-skeleton')), findsNothing);
    expect(find.byKey(const ValueKey('dataset-proposal-skeleton')), findsOneWidget);
    expect(find.byKey(const ValueKey('dataset-access-skeleton')), findsOneWidget);
  });
}
