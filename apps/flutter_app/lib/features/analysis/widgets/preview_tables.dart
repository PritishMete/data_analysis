// lib/features/analysis/widgets/preview_tables.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../dashboard/data_screen.dart';

class PreviewTables extends StatelessWidget {
  final DataScreenState state;
  const PreviewTables({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final d = state.analysisData!;
    final summary = (d['summary'] ?? {}) as Map;
    final List<dynamic> columns = summary['column_names'] ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader('Preview'),
        _buildDataTable(context, columns, d['preview']),
        const SizedBox(height: 16),
        _SectionHeader('Random Sample'),
        _buildDataTable(context, columns, d['sample']),
      ],
    );
  }

  Widget _buildDataTable(BuildContext context, List<dynamic> headers, dynamic src) {
    final rows = src is List ? src : [];
    final labelColor = CupertinoColors.label.resolveFrom(context);
    final secondaryColor = CupertinoColors.secondaryLabel.resolveFrom(context);

    if (rows.isEmpty) {
      return GlassCard(
        shape: const LiquidRoundedSuperellipse(borderRadius: 18),
        child: Text(
          'No rows to display yet.',
          style: TextStyle(color: secondaryColor, fontSize: 12),
        ),
      );
    }

    return GlassCard(
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
          columns: headers
              .map((h) => DataColumn(
            label: Text(
              h.toString(),
              style: TextStyle(
                color: secondaryColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ))
              .toList(),
          rows: rows
              .map((row) => DataRow(
            cells: headers.map((h) {
              final val = row is Map ? (row[h.toString()] ?? '') : '';
              return DataCell(Text(
                val.toString(),
                style: TextStyle(color: labelColor, fontSize: 12),
              ));
            }).toList(),
          ))
              .toList(),
        ),
      ),
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