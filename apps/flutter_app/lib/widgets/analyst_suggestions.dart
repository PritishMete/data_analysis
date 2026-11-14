import 'package:flutter/material.dart';

import '../app_colors.dart';

/// Lightweight context-aware follow-up chips shown under analytical answers.
///
/// The widget is deliberately dumb: it renders backend-approved structured
/// suggestions and dispatches the exact query through the normal chat path.
class AnalystSuggestions extends StatelessWidget {
  const AnalystSuggestions({
    super.key,
    required this.suggestions,
    required this.onSelected,
  });

  final List<Map<String, dynamic>> suggestions;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final visible = suggestions
        .where((item) => (item['query']?.toString().trim().isNotEmpty ?? false))
        .take(5)
        .toList(growable: false);
    if (visible.isEmpty) return const SizedBox.shrink();

    return Padding(
      key: const ValueKey('analyst-suggestions'),
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'You could also ask',
            style: TextStyle(
              color: TechColors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: .35,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final suggestion in visible)
                _SuggestionChip(
                  suggestion: suggestion,
                  onSelected: onSelected,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.suggestion, required this.onSelected});

  final Map<String, dynamic> suggestion;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final query = suggestion['query']?.toString().trim() ?? '';
    final label = suggestion['label']?.toString().trim();
    final text = (label == null || label.isEmpty) ? query : label;
    final reason = suggestion['reason']?.toString().trim();

    return Tooltip(
      message: reason == null || reason.isEmpty ? query : reason,
      child: ActionChip(
        key: ValueKey('analyst-suggestion-$query'),
        label: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        avatar: const Icon(Icons.arrow_outward_rounded, size: 15),
        onPressed: query.isEmpty ? null : () => onSelected(query),
        side: BorderSide(color: TechColors.borderMuted.withValues(alpha: .9)),
        backgroundColor: Colors.white.withValues(alpha: .035),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// Native structured rendering for "Summarize our analysis so far".
class AnalystSessionSummary extends StatelessWidget {
  const AnalystSessionSummary({super.key, required this.summary});

  final Map<String, dynamic> summary;

  @override
  Widget build(BuildContext context) {
    final currentScope = summary['current_scope']?.toString() ?? 'global';
    final selectedEntity = summary['selected_entity']?.toString();
    final selectedEntityType = summary['selected_entity_type']?.toString();
    final metric = summary['current_metric']?.toString();
    final filters = summary['active_filters'] is Map
        ? Map<String, dynamic>.from(summary['active_filters'] as Map)
        : const <String, dynamic>{};
    final recent = (summary['recent_analyses'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
    final reports = (summary['generated_reports'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);

    return SelectionArea(
      child: Container(
        key: const ValueKey('analyst-session-summary'),
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .035),
          border: Border.all(color: Colors.white.withValues(alpha: .08)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Analysis Summary',
              style: TextStyle(
                color: TechColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            _line('Current scope', currentScope),
            if (filters.isNotEmpty)
              _line(
                'Active filters',
                filters.entries.map((e) => '${e.key}: ${e.value}').join(' • '),
              ),
            if (selectedEntity != null && selectedEntity.isNotEmpty)
              _line(
                selectedEntityType == null || selectedEntityType.isEmpty
                    ? 'Selected entity'
                    : 'Selected ${selectedEntityType.replaceAll('_', ' ')}',
                selectedEntity,
              ),
            if (metric != null && metric.isNotEmpty) _line('Metric', metric),
            if (recent.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Recent analysis',
                style: TextStyle(
                  color: TechColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              for (final item in recent.reversed.take(6))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '• ${_analysisLabel(item)}',
                    style: const TextStyle(
                      color: TechColors.textPrimary,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
            ],
            if (reports.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Generated reports',
                style: TextStyle(
                  color: TechColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              for (final report in reports.reversed.take(5))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '• ${report['filename'] ?? report['report_type'] ?? 'Report'}${report['scope'] == null ? '' : ' — ${report['scope']}'}',
                    style: const TextStyle(
                      color: TechColors.textPrimary,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  static Widget _line(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$label: ',
                style: const TextStyle(
                  color: TechColors.textMuted,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              TextSpan(
                text: value,
                style: const TextStyle(
                  color: TechColors.textPrimary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );

  static String _analysisLabel(Map<String, dynamic> item) {
    final summary = item['summary']?.toString().trim();
    if (summary != null && summary.isNotEmpty) return summary;
    final type = item['type']?.toString().replaceAll('_', ' ') ?? 'analysis';
    final scope = item['scope']?.toString();
    final entity = item['selected_entity']?.toString();
    final pieces = <String>[type];
    if (scope != null && scope.isNotEmpty) pieces.add(scope);
    if (entity != null && entity.isNotEmpty && entity != scope) pieces.add(entity);
    return pieces.join(' — ');
  }
}
