import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/widgets/overlays/synthetic_data_confirmation_dialog.dart';

void main() {
  testWidgets('synthetic confirmation opens with safety fields and cancel returns without a write', (tester) async {
    SyntheticDataConfirmation? result;
    await tester.pumpWidget(CupertinoApp(
      home: Builder(builder: (context) => CupertinoButton(
        onPressed: () async {
          result = await SyntheticDataConfirmationDialog.show(
            context: context,
            sourceWorksheet: 'Restaurants',
            proposedColumn: 'Revenue',
            defaultMin: 0,
            defaultMax: 100000,
            defaultFormat: SyntheticNumberFormat.decimal,
            proposedOutputWorksheet: 'Hypothetical_Revenue',
            existingColumn: true,
          );
        },
        child: const Text('Open'),
      )),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Create hypothetical data'), findsOneWidget);
    expect(find.textContaining('not actual revenue'), findsOneWidget);
    expect(find.text('Minimum'), findsOneWidget);
    expect(find.text('Maximum'), findsOneWidget);
    expect(find.text('Integer'), findsOneWidget);
    expect(find.text('Decimal'), findsOneWidget);
    expect(find.text('Random seed (optional)'), findsOneWidget);
    expect(find.textContaining('original values will not be overwritten'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('Create hypothetical data'), findsNothing);
  });
}