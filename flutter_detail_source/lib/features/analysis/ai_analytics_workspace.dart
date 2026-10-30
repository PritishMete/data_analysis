import 'package:flutter/material.dart';

import '../../app_colors.dart';
import '../dashboard/data_screen.dart';
import '../neural_chat/chat_console.dart';

/// Focused AI analysis surface that reuses DataScreenState's existing
/// authenticated chat and report operations. Pipeline and data tools stay
/// in their existing Data Screen destinations.
class AiAnalyticsWorkspace extends StatelessWidget {
  final DataScreenState state;
  const AiAnalyticsWorkspace({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final summary = state.analysisData?['summary'];
    final rows = summary is Map ? summary['rows'] : null;
    final rowCount = state.uploadedFile?.dataRowCount ??
        (rows is num ? rows.toInt() : null);
    final source = state.dataSourceMode == DataSourceMode.uploadedFile
        ? (state.currentFileName ?? 'Uploaded file')
        : state.activeSheetName;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AiHeader(
            source: source,
            rowCount: rowCount,
            columns: state.detectedHeaders.length,
            managed: state.isManagedDatasetSession,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                if (box.maxWidth < 820) {
                  if (box.maxHeight < 500) {
                    // On short screens, let the two work areas scroll rather
                    // than squeezing report controls into an unusable sliver.
                    return SingleChildScrollView(
                      child: Column(
                        children: [
                          SizedBox(
                            height: 380,
                            child: _AnalysisPanel(state: state),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 520,
                            child: _ConversationPanel(state: state),
                          ),
                        ],
                      ),
                    );
                  }
                  final chatHeight =
                      (box.maxHeight * 0.64).clamp(270.0, 600.0).toDouble();
                  return Column(
                    children: [
                      SizedBox(
                        height: box.maxHeight - chatHeight - 10,
                        child: _AnalysisPanel(state: state),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: chatHeight,
                        child: _ConversationPanel(state: state),
                      ),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 5, child: _AnalysisPanel(state: state)),
                    const SizedBox(width: 12),
                    Expanded(flex: 7, child: _ConversationPanel(state: state)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AiHeader extends StatelessWidget {
  final String source;
  final int? rowCount;
  final int columns;
  final bool managed;

  const _AiHeader({
    required this.source,
    required this.rowCount,
    required this.columns,
    required this.managed,
  });

  @override
  Widget build(BuildContext context) {
    final rowLabel = rowCount == null ? 'Rows not measured' : '$rowCount rows';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            TechColors.borderActive.withValues(alpha: 0.18),
            TechColors.panelBg.withValues(alpha: 0.92),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: TechColors.borderActive.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: TechColors.borderActive.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.auto_awesome,
                color: TechColors.borderActive, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('AI Analytics',
                    style: TextStyle(
                      color: TechColors.textPrimary,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                    )),
                const SizedBox(height: 4),
                const Text(
                  'Understand findings, ask questions, and create useful reports.',
                  style: TextStyle(color: TechColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 7,
                  runSpacing: 6,
                  children: [
                    _Pill(icon: Icons.dataset_outlined,
                        label: source.isEmpty ? 'Current data source' : source),
                    _Pill(icon: Icons.table_rows_outlined, label: rowLabel),
                    _Pill(icon: Icons.view_column_outlined, label: '$columns columns'),
                    if (managed)
                      const _Pill(icon: Icons.verified_user_outlined,
                          label: 'Managed dataset'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Pill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: TechColors.panelBg.withValues(alpha: 0.82),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: TechColors.borderMuted),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: TechColors.borderActive),
      const SizedBox(width: 5),
      Text(label, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: TechColors.textMuted, fontSize: 11)),
    ]),
  );
}

class _AnalysisPanel extends StatelessWidget {
  final DataScreenState state;
  const _AnalysisPanel({required this.state});

  @override
  Widget build(BuildContext context) {
    final report = state.aiReport;
    final summary = state.analysisData?['summary'];
    final rows = summary is Map ? summary['rows'] : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 6,
          child: _Panel(
            title: 'Analysis snapshot',
            subtitle: 'Signals from the current analysis, not a second dashboard.',
            icon: Icons.insights_outlined,
            child: ListView(
              children: [
                _SnapshotRow(label: 'Detected columns',
                    value: state.detectedHeaders.length.toString(),
                    icon: Icons.view_column_outlined),
                _SnapshotRow(label: 'Rows analyzed',
                    value: rows is num ? rows.toString() : 'Not available',
                    icon: Icons.table_rows_outlined),
                _SnapshotRow(label: 'Report status',
                    value: state.isGeneratingReport
                        ? 'Generating'
                        : report == null ? 'Not generated' : 'Ready',
                    icon: Icons.description_outlined),
                const SizedBox(height: 12),
                Wrap(spacing: 7, runSpacing: 7, children: [
                  _CountChip(label: 'KPIs', value: report?.detectedKpis.length ?? 0),
                  _CountChip(label: 'Outliers', value: report?.outliers.length ?? 0),
                  _CountChip(label: 'Recommendations',
                      value: report?.recommendations.length ?? 0),
                ]),
                if (state.reportError?.isNotEmpty == true) ...[
                  const SizedBox(height: 10),
                  _Notice(message: state.reportError!),
                ],
                if (state.detailAnalysisError?.isNotEmpty == true) ...[
                  const SizedBox(height: 8),
                  _Notice(message: state.detailAnalysisError!),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          flex: 5,
          child: _Panel(
            title: 'Report & next steps',
            subtitle: 'Generate a report through the existing analysis flow.',
            icon: Icons.summarize_outlined,
            trailing: FilledButton.tonalIcon(
              onPressed: state.isGeneratingReport ? null : state.generateReport,
              icon: state.isGeneratingReport
                  ? const SizedBox(width: 15, height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow, size: 17),
              label: Text(state.isGeneratingReport ? 'Working' : 'Generate'),
            ),
            child: state.reportText?.isNotEmpty == true
                ? SingleChildScrollView(
                    child: SelectableText(state.reportText!,
                        style: const TextStyle(
                            color: TechColors.textPrimary,
                            height: 1.45, fontSize: 12)),
                  )
                : const _EmptyPrompt(
                    icon: Icons.auto_awesome_outlined,
                    title: 'No report yet',
                    message: 'Generate a report when you are ready to turn the current analysis into a summary.',
                  ),
          ),
        ),
      ],
    );
  }
}

class _ConversationPanel extends StatelessWidget {
  final DataScreenState state;
  const _ConversationPanel({required this.state});

  static const _prompts = [
    'Summarize the key findings',
    'Find unusual patterns or risks',
    'Explain the biggest changes',
    'What should I investigate next?',
  ];

  @override
  Widget build(BuildContext context) => _Panel(
    title: 'Ask your data',
    subtitle: 'Uses the existing chat and authorization flow.',
    icon: Icons.forum_outlined,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: _prompts.map((prompt) => ActionChip(
            visualDensity: VisualDensity.compact,
            avatar: const Icon(Icons.arrow_outward, size: 13),
            label: Text(prompt, style: const TextStyle(fontSize: 11)),
            onPressed: state.isSearchingChat ? null : () {
              state.chatController.text = prompt;
              state.processChatQuery();
            },
          )).toList(),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ChatConsole(state: state, fullHeight: true),
          ),
        ),
      ],
    ),
  );
}

class _Panel extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  const _Panel({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: TechColors.panelBg.withValues(alpha: 0.84),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: TechColors.borderMuted),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Icon(icon, size: 18, color: TechColors.borderActive),
          const SizedBox(width: 8),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(
                  color: TechColors.textPrimary, fontSize: 14,
                  fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(subtitle, style: const TextStyle(
                  color: TechColors.textMuted, fontSize: 11)),
            ],
          )),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ]),
        const SizedBox(height: 12),
        Expanded(child: child),
      ],
    ),
  );
}

class _SnapshotRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _SnapshotRow({required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(children: [
      Icon(icon, size: 16, color: TechColors.textMuted),
      const SizedBox(width: 9),
      Expanded(child: Text(label,
          style: const TextStyle(color: TechColors.textMuted, fontSize: 12))),
      Flexible(child: Text(value, textAlign: TextAlign.end,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: TechColors.textPrimary,
              fontSize: 12, fontWeight: FontWeight.w600))),
    ]),
  );
}

class _CountChip extends StatelessWidget {
  final String label;
  final int value;
  const _CountChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: TechColors.borderActive.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: TechColors.borderActive.withValues(alpha: 0.2)),
    ),
    child: Text('$label  $value', style: const TextStyle(
        color: TechColors.textPrimary, fontSize: 11, fontWeight: FontWeight.w600)),
  );
}

class _Notice extends StatelessWidget {
  final String message;
  const _Notice({required this.message});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: TechColors.statusRed.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: TechColors.statusRed.withValues(alpha: 0.25)),
    ),
    child: Text(message, style: const TextStyle(
        color: TechColors.textPrimary, fontSize: 11)),
  );
}

class _EmptyPrompt extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  const _EmptyPrompt({required this.icon, required this.title, required this.message});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 28, color: TechColors.textMuted),
        const SizedBox(height: 9),
        Text(title, style: const TextStyle(
            color: TechColors.textPrimary, fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        Text(message, textAlign: TextAlign.center,
            style: const TextStyle(color: TechColors.textMuted,
                fontSize: 12, height: 1.4)),
      ]),
    ),
  );
}
