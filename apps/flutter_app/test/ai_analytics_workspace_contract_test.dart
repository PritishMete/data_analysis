import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Analytics is a focused analysis and conversation command centre', () {
    final source = File(
      'lib/features/analysis/ai_analytics_workspace.dart',
    ).readAsStringSync();

    expect(source, contains('AI Analytics'));
    expect(source, contains('Analysis snapshot'));
    expect(source, contains('Ask your data'));
    expect(source, contains('Report & next steps'));
    expect(source, contains('ChatConsole(state: state, fullHeight: true)'));
    expect(source, contains('state.generateReport'));
    expect(source, contains('state.processChatQuery'));
    expect(source, isNot(contains('Data Explorer')));
    expect(source, isNot(contains('Monitoring')));
    expect(source, isNot(contains('Governance')));
    expect(source, isNot(contains('PipelineScreen')));
    expect(source, isNot(contains('runTransformationPipeline')));
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

  test('AI Analytics does not replace the existing pipeline screen', () {
    final source = File(
      'lib/features/dashboard/data_screen.dart',
    ).readAsStringSync();

    expect(source, contains('PipelineScreen(state: this)'));
    expect(source, contains('runTransformationPipeline'));
    expect(source, contains('runColumnSplitPipeline'));
    expect(source, contains('runTableBuilderPipeline'));
  });
}
