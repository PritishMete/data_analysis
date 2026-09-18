import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/widgets/overlays/ranking_limit_dialog.dart';

void main() {
  testWidgets('ranking selector exposes top options, all and custom input', (tester) async {
    RankingLimitChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async {
              result = await RankingLimitDialog.show(
                context: context,
                descending: true,
                groupingColumn: 'Cuisine',
                availableCount: 7,
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('How many Cuisines would you like to see?'), findsOneWidget);
    expect(find.text('Top 5'), findsOneWidget);
    expect(find.text('Top 10'), findsOneWidget);
    expect(find.text('Top 20'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Custom number'), findsOneWidget);
    expect(find.textContaining('7 grouped results'), findsOneWidget);

    await tester.tap(find.text('Top 10'));
    await tester.pumpAndSettle();
    expect(result?.limit, 10);
    expect(result?.all, isFalse);
  });

  testWidgets('bottom selector and cancellation do not modify the result choice', (tester) async {
    RankingLimitChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async {
              result = await RankingLimitDialog.show(
                context: context,
                descending: false,
                groupingColumn: 'Cuisine',
                availableCount: 3,
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Bottom 5'), findsOneWidget);
    expect(find.text('Bottom 10'), findsOneWidget);
    expect(find.text('Bottom 20'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
  testWidgets('custom count rejects non-positive values and accepts a positive integer', (tester) async {
    RankingLimitChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async {
              result = await RankingLimitDialog.show(
                context: context,
                descending: true,
                groupingColumn: 'Cuisine',
                availableCount: 4,
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '0');
    await tester.tap(find.text('Use Custom'));
    await tester.pump();
    expect(find.text('Enter a positive integer.'), findsOneWidget);
    expect(result, isNull);

    await tester.enterText(find.byType(TextFormField), '37');
    await tester.tap(find.text('Use Custom'));
    await tester.pumpAndSettle();
    expect(result?.limit, 37);
    expect(result?.all, isFalse);
  });
}
