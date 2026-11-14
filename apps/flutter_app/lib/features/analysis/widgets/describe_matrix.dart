// lib/features/analysis/widgets/describe_matrix.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../dashboard/data_screen.dart';

class DescribeMatrix extends StatelessWidget {
  final DataScreenState state;
  const DescribeMatrix({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final raw = state.analysisData!['describe'];
    final secondaryColor = CupertinoColors.secondaryLabel.resolveFrom(context);
    final labelColor = CupertinoColors.label.resolveFrom(context);

    if (raw is! List || raw.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader('Statistics'),
          GlassCard(
            shape: const LiquidRoundedSuperellipse(borderRadius: 18),
            child: Text(
              'Statistical summary not computed yet.',
              style: TextStyle(color: secondaryColor, fontSize: 12),
            ),
          ),
        ],
      );
    }

    final headers = Map<String, dynamic>.from(raw.first).keys.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader('Statistics'),
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
              columns: headers
                  .map((h) => DataColumn(
                label: Text(
                  h == 'index' ? 'Metric' : h,
                  style: TextStyle(
                    color: secondaryColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              ))
                  .toList(),
              rows: raw
                  .map<DataRow>((row) => DataRow(
                cells: headers
                    .map((h) => DataCell(Text(
                  row[h].toString(),
                  style: TextStyle(color: labelColor, fontSize: 12),
                )))
                    .toList(),
              ))
                  .toList(),
            ),
          ),
        ),
      ],
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