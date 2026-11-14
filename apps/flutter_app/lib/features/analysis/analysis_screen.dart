// lib/features/analysis/analysis_screen.dart
import 'package:flutter/material.dart';
import '../dashboard/data_screen.dart';

import '../neural_chat/chat_console.dart';
import 'ai_analytics_workspace.dart';
import 'analytics_reference_workspace.dart';
import 'widgets/overview_metrics.dart';
import 'widgets/quality_report.dart';
import 'widgets/preview_tables.dart';
import 'widgets/describe_matrix.dart';
import 'widgets/runtime_logs.dart';

class AnalysisScreen extends StatelessWidget {
  final DataScreenState state;
  const AnalysisScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.selectedView == 'ANALYTICS_REFERENCE') {
      return const AnalyticsReferenceWorkspace();
    }

    if (state.selectedView == 'AI_ANALYTICS') {
      return AiAnalyticsWorkspace(state: state);
    }

    final hasAnalysisData =
        state.analysisData != null && !state.analysisData!.containsKey('error');
    final showChat =
        state.selectedView == 'ALL_SYSTEMS' || state.selectedView == 'NEURAL_CHAT';
    final showOverview =
        state.selectedView == 'ALL_SYSTEMS' || state.selectedView == 'OVERVIEW';
    final showPreview =
        state.selectedView == 'ALL_SYSTEMS' || state.selectedView == 'PREVIEW';
    final showStats =
        state.selectedView == 'ALL_SYSTEMS' || state.selectedView == 'STATS';
    final showQuality =
        state.selectedView == 'ALL_SYSTEMS' || state.selectedView == 'QUALITY';
    final showLogs =
        state.selectedView == 'ALL_SYSTEMS' || state.selectedView == 'LOGS';

    if (state.selectedView == 'NEURAL_CHAT') {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: ChatConsole(state: state, fullHeight: true),
      );
    }

    // Render the selected analysis section even before a dataset is scanned.
    // The previous dashboard-level empty-state guard routed every tab to the
    // same PipelineScreen, so individual tabs did not remain category-specific.
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 150),
      children: [
        if (!hasAnalysisData) ...[
          state.buildEmptyState(),
          const SizedBox(height: 16),
        ],
        if (showChat) ...[
          ChatConsole(state: state),
          const SizedBox(height: 24),
        ],
        if (showOverview) ...[
          hasAnalysisData
              ? OverviewMetrics(state: state)
              : const _EmptyAnalysisSection(
                  title: 'Overview',
                  message: 'Scan a dataset to view row, column and duplicate metrics.',
                ),
          const SizedBox(height: 24),
        ],
        if (showQuality) ...[
          hasAnalysisData
              ? QualityReport(state: state)
              : const _EmptyAnalysisSection(
                  title: 'Data Quality',
                  message: 'Scan a dataset to view missing values, unique values and duplicates.',
                ),
          const SizedBox(height: 24),
        ],
        if (showPreview) ...[
          hasAnalysisData
              ? PreviewTables(state: state)
              : const _EmptyAnalysisSection(
                  title: 'Preview',
                  message: 'Scan a dataset to view the first rows and a random sample.',
                ),
          const SizedBox(height: 24),
        ],
        if (showStats) ...[
          hasAnalysisData
              ? DescribeMatrix(state: state)
              : const _EmptyAnalysisSection(
                  title: 'Statistics',
                  message: 'Scan a dataset to view descriptive statistics.',
                ),
          const SizedBox(height: 24),
        ],
        if (showLogs)
          hasAnalysisData
              ? RuntimeLogs(state: state)
              : const _EmptyAnalysisSection(
                  title: 'Logs',
                  message: 'Runtime and analysis logs will appear after a dataset scan.',
                ),
      ],
    );
  }
}

class _EmptyAnalysisSection extends StatelessWidget {
  final String title;
  final String message;

  const _EmptyAnalysisSection({
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
