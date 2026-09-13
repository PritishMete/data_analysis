// lib/features/analysis/analysis_screen.dart
import 'package:flutter/material.dart';
import '../dashboard/data_screen.dart';

import '../neural_chat/chat_console.dart';
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
    final showChat = state.selectedView == 'ALL_SYSTEMS' || state.selectedView == 'NEURAL_CHAT';
    final showOverview = state.selectedView == 'ALL_SYSTEMS' || state.selectedView == 'OVERVIEW';
    final showPreview = state.selectedView == 'ALL_SYSTEMS' || state.selectedView == 'PREVIEW';
    final showStats = state.selectedView == 'ALL_SYSTEMS' || state.selectedView == 'STATS';
    final showQuality = state.selectedView == 'ALL_SYSTEMS' || state.selectedView == 'QUALITY';
    final showLogs = state.selectedView == 'ALL_SYSTEMS' || state.selectedView == 'LOGS';

    // The dedicated AI CHAT view is a true full-height workspace.  It owns
    // the available viewport so the conversation can expand instead of
    // being constrained to the compact dashboard chat card.
    if (state.selectedView == 'NEURAL_CHAT') {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: ChatConsole(state: state, fullHeight: true),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (showChat) ...[
          ChatConsole(state: state),
          const SizedBox(height: 24),
        ],
        if (showOverview) ...[
          OverviewMetrics(state: state),
          const SizedBox(height: 24),
        ],
        if (showQuality) ...[
          QualityReport(state: state),
          const SizedBox(height: 24),
        ],
        if (showPreview) ...[
          PreviewTables(state: state),
          const SizedBox(height: 24),
        ],
        if (showStats) ...[
          DescribeMatrix(state: state),
          const SizedBox(height: 24),
        ],
        if (showLogs) RuntimeLogs(state: state),
      ],
    );
  }
}