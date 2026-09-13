// lib/features/analysis/widgets/quality_report.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../dashboard/data_screen.dart';

class QualityReport extends StatelessWidget {
  final DataScreenState state;
  const QualityReport({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final d = state.analysisData!;
    final summary = (d['summary'] ?? {}) as Map;
    final distribution = (d['distribution'] ?? {}) as Map;
    final List<dynamic> columns = summary['column_names'] ?? [];
    final missing = (d['missing_values'] ?? {}) as Map;
    final unique = (distribution['unique_values'] ?? d['unique_values'] ?? {}) as Map;
    final duplicates = (distribution['duplicate_values'] ?? d['duplicate_values'] ?? {}) as Map;
    final labelColor = CupertinoColors.label.resolveFrom(context);
    final secondaryColor = CupertinoColors.secondaryLabel.resolveFrom(context);

    final totalNulls = missing.values.fold<int>(0, (sum, v) => sum + (v as int));
    final columnsWithNulls = missing.values.where((v) => (v as int) > 0).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader('Data Quality'),
        GlassCard(
          padding: EdgeInsets.zero,
          shape: const LiquidRoundedSuperellipse(borderRadius: 18),
          child: Column(
            children: [
              GlassListTile(
                leading: const Icon(CupertinoIcons.exclamationmark_circle),
                title: const Text('Total null values'),
                trailing: Text(
                  '$totalNulls',
                  style: TextStyle(
                    color: totalNulls > 0 ? CupertinoColors.systemRed : CupertinoColors.systemGreen,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              GlassListTile(
                leading: const Icon(CupertinoIcons.rectangle_split_3x1),
                title: const Text('Columns affected'),
                trailing: Text(
                  '$columnsWithNulls / ${columns.length}',
                  style: TextStyle(color: labelColor, fontSize: 14, fontWeight: FontWeight.w600),
                ),
                isLast: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        GlassCard(
          padding: const EdgeInsets.all(4),
          shape: const LiquidRoundedSuperellipse(borderRadius: 18),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: WidgetStateProperty.all(Colors.transparent),
              dataRowColor: WidgetStateProperty.all(Colors.transparent),
              headingRowHeight: 40,
              dataRowMinHeight: 34,
              dataRowMaxHeight: 40,
              columnSpacing: 24,
              dividerThickness: 0.3,
              columns: [
                DataColumn(label: Text('Field', style: _headerStyle(secondaryColor))),
                DataColumn(label: Text('Null refs', style: _headerStyle(secondaryColor))),
                DataColumn(label: Text('Unique', style: _headerStyle(secondaryColor))),
                DataColumn(label: Text('Duplicates', style: _headerStyle(secondaryColor))),
              ],
              rows: columns.map<DataRow>((col) {
                final name = col.toString();
                final miss = (missing[name] ?? 0) as int;
                final uniq = (unique[name] ?? 0) as int;
                final dup = (duplicates[name] ?? 0) as int;
                return DataRow(cells: [
                  DataCell(Text(name, style: TextStyle(color: labelColor, fontSize: 12, fontWeight: FontWeight.w600))),
                  DataCell(Text(
                    miss.toString(),
                    style: TextStyle(
                      color: miss > 0 ? CupertinoColors.systemRed : CupertinoColors.systemGreen,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  )),
                  DataCell(Text(uniq.toString(), style: TextStyle(color: secondaryColor, fontSize: 12))),
                  DataCell(Text(
                    dup.toString(),
                    style: TextStyle(
                      color: dup > 0 ? CupertinoColors.systemOrange : CupertinoColors.systemGreen,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  )),
                ]);
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  TextStyle _headerStyle(Color color) => TextStyle(
    color: color,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.3,
  );
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