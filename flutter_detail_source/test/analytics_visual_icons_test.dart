import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/features/analysis/analytics_visual_icons.dart';

void main() {
  group('AnalyticsVisualIcons chart catalogue', () {
    test('provides a semantic icon for every documented chart type', () {
      expect(AnalyticsVisualIcons.chartNames, isNotEmpty);
      for (final name in AnalyticsVisualIcons.chartNames) {
        expect(
          AnalyticsVisualIcons.chart(name),
          isNot(Icons.analytics_outlined),
          reason: '$name must have an explicit chart icon mapping',
        );
      }
    });

    test('keeps the chart catalogue free of duplicate labels', () {
      expect(
        AnalyticsVisualIcons.chartNames.toSet().length,
        AnalyticsVisualIcons.chartNames.length,
      );
    });
  });

  group('AnalyticsVisualIcons analytical storytelling', () {
    test('maps each existing narrative stage to a meaningful icon', () {
      const stages = ['Describe', 'Diagnose', 'Predict', 'Prescribe'];
      for (final stage in stages) {
        expect(
          AnalyticsVisualIcons.narrativeStage(stage),
          isNot(Icons.auto_stories_outlined),
          reason: '$stage must have an explicit stage icon',
        );
      }
    });

    test('maps vocabulary categories to visible icons', () {
      const categories = [
        'Trend and movement',
        'Magnitude and scale',
        'Distribution and variation',
        'Performance and evaluation',
        'Comparison and context',
        'Relationships and causes',
        'Forecasting and prediction',
        'Data quality and reliability',
      ];
      for (final category in categories) {
        expect(
          AnalyticsVisualIcons.vocabulary('Representative term', category),
          isNot(Icons.lightbulb_outline),
          reason: '$category must have a category-specific icon',
        );
      }
    });
  });
}
