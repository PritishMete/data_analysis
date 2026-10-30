import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Analytics workspace exposes all seven dedicated sections', () {
    final source = File(
      'lib/features/analysis/ai_analytics_workspace.dart',
    ).readAsStringSync();

    for (final section in const [
      'Overview',
      'Data Explorer',
      'AI Analyst',
      'Reports',
      'Monitoring',
      'Governance',
      'History',
    ]) {
      expect(source, contains("'$section'"));
    }
  });

  test('AI Analytics route renders before a workbook scan is present', () {
    final source = File(
      'lib/features/dashboard/data_screen.dart',
    ).readAsStringSync();

    final workspaceRoute = source.indexOf("if (selectedView == 'AI_ANALYTICS')");
    final emptyStateGuard = source.indexOf(
      "if (analysisData == null || analysisData!.containsKey('error'))",
    );
    expect(workspaceRoute, greaterThanOrEqualTo(0));
    expect(emptyStateGuard, greaterThan(workspaceRoute));
    expect(source, contains('NavigationTabs(state: this)'));
    expect(
      source,
      isNot(contains("if (analysisData != null) NavigationTabs(state: this)")),
    );
  });

  test('AI Analytics reuses the existing report and analyst operations', () {
    final source = File(
      'lib/features/analysis/ai_analytics_workspace.dart',
    ).readAsStringSync();

    expect(source, contains('state.generateReport'));
    expect(source, contains('state.processChatQuery'));
    expect(source, contains('ChatConsole(state: state'));
    expect(
      source,
      contains('Workspace navigation does not grant dataset access.'),
    );
  });
}
