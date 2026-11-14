import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/widgets/analyst_suggestions.dart';

void main() {
  testWidgets('renders contextual suggestions and dispatches exact query', (tester) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnalystSuggestions(
            suggestions: const [
              {
                'id': 'region-year',
                'label': 'How did North perform in 2025?',
                'query': 'How did North perform in 2025?',
                'reason': 'Add a year scope.',
              },
              {
                'id': 'region-category',
                'label': 'Which categories contribute most?',
                'query': "Which categories contribute most to North's profit?",
              },
            ],
            onSelected: (query) => selected = query,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('analyst-suggestions')), findsOneWidget);
    expect(find.text('You could also ask'), findsOneWidget);
    await tester.tap(find.text('How did North perform in 2025?'));
    await tester.pump();
    expect(selected, 'How did North perform in 2025?');
  });

  testWidgets('hides suggestion section when empty', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnalystSuggestions(
            suggestions: const [],
            onSelected: (_) {},
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('analyst-suggestions')), findsNothing);
  });

  testWidgets('session summary renders scope filters history and reports', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnalystSessionSummary(
            summary: const {
              'current_scope': 'North',
              'active_filters': {'year': 2025, 'business_region': 'North'},
              'selected_entity': 'North',
              'selected_entity_type': 'business_region',
              'current_metric': 'profit',
              'recent_analyses': [
                {
                  'type': 'ranking',
                  'scope': 'global',
                  'selected_entity': 'North',
                  'summary': 'North ranked first by profit',
                }
              ],
              'generated_reports': [
                {
                  'filename': 'Vibe_Analysis_North_2025.pdf',
                  'scope': 'North / 2025',
                }
              ],
            },
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('analyst-session-summary')), findsOneWidget);
    expect(find.textContaining('North'), findsWidgets);
    expect(find.textContaining('2025'), findsWidgets);
    expect(find.textContaining('North ranked first by profit'), findsOneWidget);
    expect(find.textContaining('Vibe_Analysis_North_2025.pdf'), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('suggestion chips wrap without horizontal overflow', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: AnalystSuggestions(
              suggestions: List.generate(
                5,
                (index) => {
                  'label': 'A longer contextual follow-up question number $index',
                  'query': 'query-$index',
                },
              ),
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
