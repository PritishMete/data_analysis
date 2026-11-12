import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('analytics guide is reachable before the first dataset scan', () {
    final source = File(
      'lib/features/dashboard/data_screen.dart',
    ).readAsStringSync();

    final guideRoute = source.indexOf(
      "if (selectedView == 'ANALYTICS_REFERENCE')",
      source.indexOf('Widget _buildBody()'),
    );
    final loadingGuard = source.indexOf(
      'if (isLoading)',
      source.indexOf('Widget _buildBody()'),
    );
    final emptyStateGuard = source.indexOf(
      "if (analysisData == null || analysisData!.containsKey('error'))",
      source.indexOf('Widget _buildBody()'),
    );

    expect(guideRoute, greaterThanOrEqualTo(0));
    expect(loadingGuard, greaterThan(guideRoute));
    expect(emptyStateGuard, greaterThan(guideRoute));
    expect(source, contains('return AnalysisScreen(state: this);'));
  });

  test('analytics guide screen owns the guide route and catalog tabs', () {
    final source = File(
      'lib/features/analysis/analysis_screen.dart',
    ).readAsStringSync();

    expect(source, contains("state.selectedView == 'ANALYTICS_REFERENCE'"));
    expect(source, contains('AnalyticsReferenceWorkspace()'));

    final guide = File(
      'lib/features/analysis/analytics_reference_workspace.dart',
    ).readAsStringSync();
    expect(guide, contains('Chart guide'));
    expect(guide, contains('Analytical vocabulary'));
  });
}
