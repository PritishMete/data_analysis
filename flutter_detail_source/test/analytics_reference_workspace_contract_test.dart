import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String dataScreen;
  late String analysisScreen;
  late String guide;

  setUpAll(() {
    dataScreen = File('lib/features/dashboard/data_screen.dart').readAsStringSync();
    analysisScreen = File('lib/features/analysis/analysis_screen.dart').readAsStringSync();
    guide = File('lib/features/analysis/analytics_reference_workspace.dart').readAsStringSync();
  });

  test('Analytics Guide is routed before loading and no-dataset guards', () {
    final body = dataScreen.indexOf('Widget _buildBody()');
    final guideRoute = dataScreen.indexOf("if (selectedView == 'ANALYTICS_REFERENCE')", body);
    final loadingGuard = dataScreen.indexOf('if (isLoading)', body);
    final emptyStateGuard = dataScreen.indexOf("if (analysisData == null || analysisData!.containsKey('error'))", body);

    expect(guideRoute, greaterThanOrEqualTo(0));
    expect(loadingGuard, greaterThan(guideRoute));
    expect(emptyStateGuard, greaterThan(guideRoute));
    expect(dataScreen.substring(guideRoute, loadingGuard), contains('return AnalysisScreen(state: this);'));
  });

  test('guide renders all five learning sections and remains dataset independent', () {
    for (final label in [
      'Overview',
      'Analytical vocabulary',
      'Chart selection',
      'Analytical methods',
      'Interpret findings',
    ]) {
      expect(guide, contains(label));
    }
    expect(guide, contains('Dataset-independent analytical reference'));
    expect(guide, isNot(contains('analysisData')));
    expect(guide, isNot(contains('scanDataset')));
  });

  test('vocabulary contains the requested analytical categories and distinctions', () {
    for (final term in [
      'Growth / increase', 'Surged', 'Decline / decrease', 'Stable / no change',
      'Fluctuation', 'Peak', 'Trough', 'Recovery', 'Reversal', 'Acceleration',
      'Deceleration', 'Significant', 'Substantial', 'Material', 'Marginal',
      'Incremental', 'Negligible', 'Nominal', 'Proportional', 'Average (mean)',
      'Median', 'Mode', 'Variance', 'Standard deviation', 'Skewness', 'Kurtosis',
      'Outlier', 'Quartile', 'Percentile', 'Distribution', 'Deviation',
      'Outperformed', 'Underperformed', 'Exceeded expectations', 'Fell short',
      'Optimal', 'Suboptimal', 'Favorable', 'Adverse', 'Efficiency', 'Productivity',
      'Year-over-Year (YoY)', 'Month-over-Month (MoM)', 'Quarter-over-Quarter (QoQ)',
      'Period-over-Period', 'Benchmark', 'Baseline', 'Relative change',
      'Absolute change', 'Correlation', 'Positive correlation', 'Negative correlation',
      'Causation', 'Contributing factor', 'Driver', 'Impact', 'Dependency',
      'Attribution', 'Projection', 'Forecast', 'Extrapolation', 'Trendline',
      'Seasonality', 'Moving average', 'Confidence interval', 'Prediction',
      'Scenario analysis', 'Completeness', 'Accuracy', 'Consistency', 'Validity',
      'Uniqueness', 'Missing values', 'Duplicate records', 'Data integrity',
    ]) {
      expect(guide.toLowerCase(), contains(term.toLowerCase()), reason: term);
    }
    expect(guide, contains('When to use'));
    expect(guide, contains('Professional example'));
    expect(guide, contains('Statistical significance is not automatically commercial importance'));
  });

  test('chart catalogue covers the requested chart families and decision guidance', () {
    for (final chart in [
      'Bar chart', 'Column chart', 'Grouped bar chart', 'Stacked bar chart',
      'Lollipop chart', 'Line chart', 'Area chart', 'Stacked area chart',
      'Sparkline', 'Moving average chart', 'Pie chart', 'Donut chart', 'Treemap',
      '100% stacked bar chart', 'Histogram', 'Box plot', 'Violin plot',
      'Density plot', 'Frequency polygon', 'Scatter plot', 'Bubble chart',
      'Heatmap', 'Correlation matrix', 'Waterfall chart', 'Pareto chart',
      'Decomposition chart', 'Funnel chart', 'Sankey diagram', 'Choropleth map',
      'Symbol map', 'Geographic heatmap', 'KPI card', 'Gauge chart',
      'Bullet chart', 'Actual vs target chart', 'Control chart', 'Run chart',
      'Radar chart', 'Gantt chart', 'Calendar heatmap', 'Candlestick chart',
    ]) {
      expect(guide.toLowerCase(), contains(chart.toLowerCase()), reason: chart);
    }
    expect(guide, contains('Data required'));
    expect(guide, contains('Question answered'));
    expect(guide, contains('Strengths'));
    expect(guide, contains('Limitations'));
    expect(guide, contains('Correlation does not prove causation'));
  });

  test('methods and interpretation examples cover all four analytics levels', () {
    for (final term in [
      'Descriptive analytics', 'Diagnostic analytics', 'Predictive analytics',
      'Prescriptive analytics', 'Root cause analysis', 'Linear regression',
      'Time-series forecasting', 'Classification', 'Optimization',
      'Scenario planning', 'Sensitivity analysis', 'Decision analysis',
      'Resource allocation', 'Revenue growth', 'Revenue up, profit down',
      'Sales target variance', 'Expense overrun', 'Output per input',
      'Performance against benchmark', 'Retention movement', 'Cycle-time improvement',
      'Branch below benchmark', 'Forecast with uncertainty',
    ]) {
      expect(guide.toLowerCase(), contains(term.toLowerCase()), reason: term);
    }
    expect(guide, contains('Four levels of analytical language'));
    expect(guide, contains('Confirmed cause'));
  });

  test('search, category filtering, empty results and chart helper are functional', () {
    expect(guide, contains('onChanged: (v) => setState(() => query'));
    expect(guide, contains('e.searchable.contains(query)'));
    expect(guide, contains('category == e.category'));
    expect(guide, contains('_Empty(empty)'));
    expect(guide, contains('Recommended:'));
    expect(guide, contains('onQuestionChanged'));
    expect(guide, contains('questions = <String, String>'));
  });

  test('guide provides a return action to the Data Workspace', () {
    expect(analysisScreen, contains('AnalyticsReferenceWorkspace('));
    expect(analysisScreen, contains("state.selectedView = 'ALL_SYSTEMS'"));
    expect(guide, contains('Back to Data Workspace'));
  });

  test('Pipeline routing remains present and independent of the guide', () {
    expect(dataScreen, contains('PipelineScreen(state: this)'));
    expect(dataScreen, contains('selectedView == "PIPELINES"'));
    expect(dataScreen, contains("selectedView == 'ANALYTICS_REFERENCE'"));
  });

  test('guide includes responsive layouts for narrow and wide screens', () {
    expect(guide, contains('LayoutBuilder'));
    expect(guide, contains('constraints.maxWidth < 560'));
    expect(guide, contains('constraints.maxWidth > 850'));
    expect(guide, contains('TabBarView'));
  });
}
