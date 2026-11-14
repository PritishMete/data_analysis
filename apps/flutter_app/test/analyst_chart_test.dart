import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liquid_glass_widgets/widgets/analyst_chart.dart';

void main() {
  const lineSpec = {
    'chart_type': 'line',
    'title': 'Monthly Revenue and Profit',
    'x_role': 'month',
    'series': [
      {'key': 'revenue', 'label': 'Revenue', 'format': 'currency'},
      {'key': 'profit', 'label': 'Profit', 'format': 'currency'},
    ],
    'rows': [
      {'month': '2024-01', 'revenue': 100.0, 'profit': 20.0},
      {'month': '2024-02', 'revenue': 120.0, 'profit': 25.0},
    ],
  };
  const barSpec = {
    'chart_type': 'bar',
    'title': 'Profit by Business Region',
    'x_role': 'business_region',
    'series': [
      {'key': 'profit', 'label': 'Profit', 'format': 'currency'},
    ],
    'rows': [
      {'business_region': 'North', 'profit': 200.0},
      {'business_region': 'South', 'profit': 150.0},
    ],
  };

  testWidgets('renders line chart inside a bounded response', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: AnalystChart(spec: lineSpec))));
    expect(find.byKey(const Key('native-analyst-chart')), findsOneWidget);
    expect(find.text('Monthly Revenue and Profit'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders bar chart responsively without overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: AnalystChart(spec: barSpec))));
    expect(find.text('Profit by Business Region'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
