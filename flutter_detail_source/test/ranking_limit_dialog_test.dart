import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/src/renderer/liquid_glass_renderer.dart';
import '../lib/widgets/interactive/glass_button.dart';
import '../lib/widgets/overlays/ranking_limit_dialog.dart';

void main() {
  Widget host(Widget child, {double width = 320, double height = 700}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: height,
            child: child,
          ),
        ),
      ),
    );
  }

  test('ranking choices preserve explicit count and All state', () {
    const topTen = RankingLimitChoice.count(10);
    const all = RankingLimitChoice.all();

    expect(topTen.limit, 10);
    expect(topTen.all, isFalse);
    expect(all.limit, isNull);
    expect(all.all, isTrue);
  });

  test('custom ranking count accepts positive integers and rejects invalid values', () {
    expect(RankingLimitDialog.parseCustomCount('1'), 1);
    expect(RankingLimitDialog.parseCustomCount('37'), 37);
    expect(RankingLimitDialog.parseCustomCount('0'), isNull);
    expect(RankingLimitDialog.parseCustomCount('-5'), isNull);
    expect(RankingLimitDialog.parseCustomCount('1.5'), isNull);
    expect(RankingLimitDialog.parseCustomCount('abc'), isNull);
    expect(RankingLimitDialog.parseCustomCount(''), isNull);
    expect(RankingLimitDialog.parseCustomCount(null), isNull);
  });

  testWidgets('ranking options render as a balanced 2 by 2 rounded grid', (tester) async {
    await tester.pumpWidget(
      host(
        RankingLimitOptionGrid(
          direction: 'Bottom',
          onSelected: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Bottom 5'), findsOneWidget);
    expect(find.text('Bottom 10'), findsOneWidget);
    expect(find.text('Bottom 20'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    expect(find.byType(GlassButton), findsNWidgets(4));
    expect(find.byType(FocusableActionDetector), findsNWidgets(4));

    final buttons = find.byType(GlassButton);
    final first = tester.getRect(buttons.at(0));
    final second = tester.getRect(buttons.at(1));
    final third = tester.getRect(buttons.at(2));
    final fourth = tester.getRect(buttons.at(3));

    expect(first.width, closeTo(second.width, 0.01));
    expect(first.width, closeTo(third.width, 0.01));
    expect(first.height, closeTo(third.height, 0.01));
    expect(first.left, lessThan(second.left));
    expect(third.left, lessThan(fourth.left));
    expect(first.top, closeTo(second.top, 0.01));
    expect(third.top, greaterThan(first.top));
    expect(third.top, closeTo(fourth.top, 0.01));

    for (final element in buttons.evaluate()) {
      final button = element.widget as GlassButton;
      expect(button.shape, isA<LiquidRoundedSuperellipse>());
    }

    expect(tester.takeException(), isNull);
  });

  testWidgets('ranking grid keeps two columns in a narrow taskpane', (tester) async {
    await tester.pumpWidget(
      host(
        RankingLimitOptionGrid(
          direction: 'Top',
          onSelected: (_) {},
        ),
        width: 220,
      ),
    );
    await tester.pump();

    final buttons = find.byType(GlassButton);
    expect(buttons, findsNWidgets(4));

    final first = tester.getRect(buttons.at(0));
    final second = tester.getRect(buttons.at(1));
    final third = tester.getRect(buttons.at(2));

    expect(first.width, lessThanOrEqualTo(104));
    expect(first.width, closeTo(second.width, 0.01));
    expect(third.top, greaterThan(first.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom section rejects non-positive values and accepts positive integer', (tester) async {
    int? selected;
    await tester.pumpWidget(
      host(
        RankingCustomNumberSection(
          onSelected: (value) => selected = value,
        ),
      ),
    );
    await tester.pump();

    final field = find.byType(TextFormField);
    await tester.enterText(field, '0');
    await tester.tap(find.text('Use Custom'));
    await tester.pump();

    expect(selected, isNull);
    expect(find.text('Enter a positive integer.'), findsOneWidget);

    await tester.enterText(field, '37');
    await tester.tap(find.text('Use Custom'));
    await tester.pump();

    expect(selected, 37);
    expect(tester.takeException(), isNull);
  });
}
