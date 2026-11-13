import 'package:flutter/material.dart';

/// Semantic icon catalogue for the Analytics Learning Workspace.
///
/// The chart symbols intentionally use distinct silhouettes so users can
/// recognize the visual task before reading its description. Story vocabulary
/// uses the same compact, outlined Material icon language as the workspace.
class AnalyticsVisualIcons {
  AnalyticsVisualIcons._();

  static const chartNames = <String>[
    'Bar chart', 'Column chart', 'Grouped bar chart', 'Stacked bar chart',
    'Lollipop chart', 'Line chart', 'Area chart', 'Stacked area chart',
    'Sparkline', 'Moving average chart', 'Pie chart', 'Donut chart',
    'Treemap', '100% stacked bar chart', 'Histogram', 'Box plot',
    'Violin plot', 'Density plot', 'Frequency polygon', 'Scatter plot',
    'Bubble chart', 'Heatmap', 'Correlation matrix', 'Waterfall chart',
    'Pareto chart', 'Decomposition chart', 'Funnel chart', 'Sankey diagram',
    'Choropleth map', 'Symbol map', 'Geographic heatmap', 'KPI card',
    'Gauge chart', 'Bullet chart', 'Actual vs target chart', 'Control chart',
    'Run chart', 'Radar chart', 'Gantt chart', 'Calendar heatmap',
    'Candlestick chart',
  ];

  static IconData chart(String title) => switch (title) {
    'Bar chart' => Icons.bar_chart,
    'Column chart' => Icons.insert_chart,
    'Grouped bar chart' => Icons.view_column,
    'Stacked bar chart' => Icons.stacked_bar_chart,
    'Lollipop chart' => Icons.format_list_numbered,
    'Line chart' => Icons.show_chart,
    'Area chart' => Icons.show_chart,
    'Stacked area chart' => Icons.stacked_line_chart,
    'Sparkline' => Icons.multiline_chart,
    'Moving average chart' => Icons.trending_up,
    'Pie chart' => Icons.pie_chart,
    'Donut chart' => Icons.donut_large,
    'Treemap' => Icons.grid_view,
    '100% stacked bar chart' => Icons.percent,
    'Histogram' => Icons.equalizer,
    'Box plot' => Icons.tune,
    'Violin plot' => Icons.graphic_eq,
    'Density plot' => Icons.waves,
    'Frequency polygon' => Icons.timeline,
    'Scatter plot' => Icons.scatter_plot,
    'Bubble chart' => Icons.bubble_chart,
    'Heatmap' => Icons.grid_on,
    'Correlation matrix' => Icons.table_chart,
    'Waterfall chart' => Icons.stacked_bar_chart,
    'Pareto chart' => Icons.bar_chart,
    'Decomposition chart' => Icons.account_tree,
    'Funnel chart' => Icons.filter_alt,
    'Sankey diagram' => Icons.swap_horiz,
    'Choropleth map' => Icons.map,
    'Symbol map' => Icons.location_on,
    'Geographic heatmap' => Icons.whatshot,
    'KPI card' => Icons.dashboard,
    'Gauge chart' => Icons.speed,
    'Bullet chart' => Icons.linear_scale,
    'Actual vs target chart' => Icons.flag,
    'Control chart' => Icons.monitor_heart,
    'Run chart' => Icons.timeline,
    'Radar chart' => Icons.radar,
    'Gantt chart' => Icons.view_timeline,
    'Calendar heatmap' => Icons.calendar_month,
    'Candlestick chart' => Icons.show_chart,
    _ => Icons.analytics_outlined,
  };

  static IconData vocabulary(String title, String category) {
    switch (title.toLowerCase()) {
      case 'growth / increase':
      case 'surged':
      case 'recovery':
      case 'acceleration':
        return Icons.trending_up;
      case 'decline / decrease':
      case 'fell short':
      case 'underperformed':
      case 'adverse':
        return Icons.trending_down;
      case 'stable / no change':
      case 'baseline':
        return Icons.horizontal_rule;
      case 'fluctuation':
      case 'variance':
        return Icons.multiline_chart;
      case 'peak':
        return Icons.vertical_align_top;
      case 'trough':
        return Icons.vertical_align_bottom;
      case 'significant':
      case 'substantial':
      case 'material':
        return Icons.stacked_bar_chart;
      case 'marginal':
      case 'incremental':
      case 'negligible':
        return Icons.linear_scale;
      case 'outperformed':
      case 'exceeded expectations':
      case 'optimal':
      case 'favorable':
        return Icons.thumb_up_alt_outlined;
      case 'correlation':
      case 'association':
      case 'dependency':
        return Icons.hub_outlined;
      case 'causation':
      case 'contributing factor':
      case 'driver':
        return Icons.account_tree_outlined;
      case 'forecast':
      case 'projection':
      case 'prediction':
        return Icons.query_stats;
      case 'outlier':
        return Icons.warning_amber_rounded;
      case 'average (mean)':
      case 'median':
      case 'mode':
        return Icons.functions;
      default:
        return switch (category) {
          'Trend and movement' => Icons.show_chart,
          'Magnitude and scale' => Icons.stacked_bar_chart,
          'Distribution and variation' => Icons.equalizer,
          'Performance and evaluation' => Icons.assessment_outlined,
          'Comparison and context' => Icons.compare_arrows,
          'Relationships and causes' => Icons.hub_outlined,
          'Forecasting and prediction' => Icons.query_stats,
          'Data quality and reliability' => Icons.verified_outlined,
          _ => Icons.lightbulb_outline,
        };
    }
  }

  static IconData narrativeStage(String stage) => switch (stage) {
    'Describe' => Icons.query_stats,
    'Diagnose' => Icons.manage_search,
    'Predict' => Icons.trending_up,
    'Prescribe' => Icons.task_alt,
    _ => Icons.auto_stories_outlined,
  };
}
