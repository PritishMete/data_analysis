import 'package:flutter/material.dart';

import '../../app_colors.dart';
import '../dashboard/data_screen.dart';
import '../neural_chat/chat_console.dart';

/// A focused analytics workspace that combines report signals and natural
/// language exploration without creating a second data-access path. Queries
/// continue through DataScreenState's existing privacy and authorization flow.
class AiAnalyticsWorkspace extends StatelessWidget {
  final DataScreenState state;

  const AiAnalyticsWorkspace({super.key, required this.state});

  static const List<String> _suggestedPrompts = <String>[
    'Summarize the most important findings',
    'Find unusual patterns and possible risks',
    'Compare the strongest and weakest metrics',
    'What should I investigate next?',
  ];

  @override
  Widget build(BuildContext context) {
    final report = state.aiReport;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: TechColors.borderActive.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: TechColors.borderActive.withValues(alpha: 0.4),
                  ),
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  color: TechColors.borderActive,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI Analytics Workspace',
                      style: TextStyle(
                        color: TechColors.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Explore your data, investigate trends, and turn findings into next steps.',
                      style: TextStyle(
                        color: TechColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: state.isGeneratingReport
                    ? null
                    : () {
                        state.generateReport();
                      },
                icon: state.isGeneratingReport
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.assessment_outlined, size: 18),
                label: Text(state.isGeneratingReport ? 'Working…' : 'Generate report'),
              ),
            ],
          ),
          if (state.reportError?.isNotEmpty == true) ...[
            const SizedBox(height: 10),
            _WorkspaceNotice(message: state.reportError!),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _MetricCard(
                label: 'DETECTED KPIs',
                value: '${report?.detectedKpis.length ?? 0}',
                icon: Icons.insights_outlined,
              ),
              _MetricCard(
                label: 'RECOMMENDATIONS',
                value: '${report?.recommendations.length ?? 0}',
                icon: Icons.lightbulb_outline,
              ),
              _MetricCard(
                label: 'OUTLIER FINDINGS',
                value: '${report?.outliers.length ?? 0}',
                icon: Icons.query_stats,
              ),
              _MetricCard(
                label: 'REPORT STATUS',
                value: report == null ? 'Not run' : 'Available',
                icon: report == null
                    ? Icons.hourglass_empty
                    : Icons.check_circle_outline,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'QUICK START',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: _suggestedPrompts
                .map(
                  (prompt) => ActionChip(
                    avatar: const Icon(Icons.arrow_outward, size: 14),
                    label: Text(prompt),
                    onPressed: state.isSearchingChat
                        ? null
                        : () {
                            state.chatController.text = prompt;
                            state.processChatQuery();
                          },
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ChatConsole(state: state, fullHeight: true),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 150, maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: TechColors.panelBg.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TechColors.borderMuted),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: TechColors.borderActive),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: TechColors.textMuted,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: TechColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceNotice extends StatelessWidget {
  final String message;

  const _WorkspaceNotice({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TechColors.statusRed.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TechColors.statusRed.withValues(alpha: 0.4)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: TechColors.textPrimary, fontSize: 12),
      ),
    );
  }
}
