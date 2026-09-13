// lib/features/analysis/widgets/overview_metrics.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../dashboard/data_screen.dart';

class OverviewMetrics extends StatelessWidget {
  final DataScreenState state;
  const OverviewMetrics({super.key, required this.state});

  String get _sourceLabel {
    if (state.dataSourceMode == DataSourceMode.uploadedFile && state.uploadedFile != null) {
      return '${state.uploadedFile!.fileName} · ${state.uploadedFile!.formatLabel}';
    }
    if (kIsWeb) return state.selectedSourceSheet ?? 'Active Selection';
    return 'Local File Stream';
  }

  @override
  Widget build(BuildContext context) {
    final d = state.analysisData!;
    final summary = (d['summary'] ?? {}) as Map;
    final List<dynamic> columns = summary['column_names'] ?? [];
    final duplicatesMap = (d['duplicates'] ?? {}) as Map;
    final duplicates = (duplicatesMap['count'] ?? 0) as int;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader('Overview'),
        GlassCard(
          padding: EdgeInsets.zero,
          shape: const LiquidRoundedSuperellipse(borderRadius: 18),
          child: Column(
            children: [
              GlassListTile(
                leading: const Icon(CupertinoIcons.rectangle_stack),
                title: const Text('Rows'),
                trailing: Text('${summary['rows'] ?? 0}', style: _valueStyle(context)),
              ),
              GlassListTile(
                leading: const Icon(CupertinoIcons.rectangle_split_3x1),
                title: const Text('Columns'),
                trailing: Text('${summary['columns'] ?? 0}', style: _valueStyle(context)),
              ),
              GlassListTile(
                leading: const Icon(CupertinoIcons.square_stack_3d_down_right),
                title: const Text('Duplicate rows'),
                trailing: Text(
                  '$duplicates',
                  style: _valueStyle(
                    context,
                    color: duplicates > 0 ? CupertinoColors.systemRed : CupertinoColors.systemGreen,
                  ),
                ),
              ),
              GlassListTile(
                leading: const Icon(CupertinoIcons.arrow_down_doc),
                title: const Text('Source'),
                subtitle: Text(_sourceLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
                isLast: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        _SectionHeader('Detected Columns'),
        GlassCard(
          shape: const LiquidRoundedSuperellipse(borderRadius: 18),
          child: columns.isEmpty
              ? Text(
            'No columns detected yet.',
            style: TextStyle(color: CupertinoColors.secondaryLabel.resolveFrom(context), fontSize: 12),
          )
              : Wrap(
            spacing: 8,
            runSpacing: 8,
            children: columns
                .map((c) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: CupertinoColors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: CupertinoColors.white.withValues(alpha: 0.1)),
              ),
              child: Text(
                c.toString(),
                style: TextStyle(
                  color: CupertinoColors.label.resolveFrom(context),
                  fontSize: 12,
                ),
              ),
            ))
                .toList(),
          ),
        ),
      ],
    );
  }

  TextStyle _valueStyle(BuildContext context, {Color? color}) {
    return TextStyle(
      color: color ?? CupertinoColors.label.resolveFrom(context),
      fontSize: 14,
      fontWeight: FontWeight.w600,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}