import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liquid_glass_widgets/widgets/analyst_quality_message.dart';

void main() {
  testWidgets('renders the structured analyst response without nested vertical lists', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: AnalystQualityMessage(response: {
          'response_type': 'analyst_quality_response',
          'intro': 'Customer data quality analysis identified 2 confirmed issues requiring attention.',
          'confirmed_issues': [
            {
              'number': 1,
              'title': 'Chronology issue',
              'severity': 'high',
              'summary': 'Orders precede signup.',
              'facts': ['10 customers are affected.'],
              'examples': {'columns': ['Customer', 'Signup date', 'Order date'], 'rows': [{'Customer': 'C1', 'Signup date': '2025-05-10', 'Order date': '2025-01-01'}]},
              'impact': 'Cohort analysis may be unreliable.',
            },
            {
              'number': 2,
              'title': 'Duplicate customers',
              'severity': 'medium',
              'summary': 'Customer identifiers repeat.',
              'facts': ['2 duplicate groups.'],
              'examples': {'columns': ['Customer ID'], 'rows': [{'Customer ID': 'C2'}]},
              'impact': 'Dimension joins need review.',
            },
          ],
          'minor_observations': [
            {'area': 'Names', 'finding': 'Names appear placeholder-like.'},
            {'area': 'Age', 'finding': 'Age is available.'},
          ],
          'passed_checks': ['Dates parse.', 'No orphan IDs.', 'No conflicting duplicates.'],
          'recommendations': ['Investigate chronology.', 'Resolve duplicates.', 'Define missing-reference handling.'],
        })),
      ),
    ));
    expect(find.text('Confirmed issues'), findsOneWidget);
    expect(find.text('1. Chronology issue'), findsOneWidget);
    expect(find.text('HIGH'), findsOneWidget);
    expect(find.text('MEDIUM'), findsOneWidget);
    expect(find.text('Signup date'), findsOneWidget);
    expect(find.text('10 customers are affected.'), findsOneWidget);
    expect(find.text('C1'), findsOneWidget);
    expect(find.text('Impact'), findsNWidgets(2));
    expect(find.text('Minor observations'), findsOneWidget);
    expect(find.text('What is not wrong'), findsOneWidget);
    expect(find.text('Recommended next steps'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    expect(find.byType(SingleChildScrollView), findsNWidgets(4));
  });

  test('structured copy uses projected human-readable evidence columns', () {
    final copied = AnalystQualityMessage.toCopyText({
      'response_type': 'analyst_quality_response',
      'intro': 'Customer data quality analysis identified 1 confirmed issue requiring attention.',
      'confirmed_issues': [
        {
          'number': 1,
          'title': 'Missing Customer references',
          'severity': 'medium',
          'summary': 'Orders have no Customer reference.',
          'facts': ['Referential coverage is 100.00%.'],
          'examples': {
            'columns': ['Order ID', 'Order date', 'Customer ID'],
            'rows': [
              {'Order ID': 'O1', 'Order date': '2025-01-01', 'Customer ID': 'Missing'},
            ],
          },
          'impact': 'Orders cannot be attributed to a customer.',
        },
      ],
      'minor_observations': [
        {'area': 'Highly regular name pattern', 'finding': 'May be expected demo data.'},
      ],
      'passed_checks': ['No orphan Customer IDs were detected.'],
      'recommendations': ['Define missing-reference handling.'],
    });

    expect(copied, contains('Customer data quality analysis identified'));
    expect(copied, contains('| Order ID | Order date | Customer ID |'));
    expect(copied, isNot(contains('sales_amount')));
    expect(copied, contains('MINOR OBSERVATIONS'));
    expect(copied, contains('WHAT IS NOT WRONG'));
    expect(copied, contains('RECOMMENDED NEXT STEPS'));
  });
}
