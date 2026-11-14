import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/features/dashboard/app_bar_actions.dart';

void main() {
  testWidgets('system status button renders without narrow viewport overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const CupertinoApp(
        home: CupertinoPageScaffold(
          child: Align(alignment: Alignment.topRight, child: SystemStatusButton()),
        ),
      ),
    );

    expect(find.byType(SystemStatusButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
