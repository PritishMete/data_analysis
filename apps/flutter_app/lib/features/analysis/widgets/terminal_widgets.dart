// lib/features/analysis/widgets/terminal_widgets.dart
//
// Shared glass primitives for the cyberpunk terminal UI.
// Import this in every analysis widget instead of duplicating
// _buildSectionLabel / _buildDataTable locally.
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../../../app_colors.dart';

// =============================================================================
// TerminalSectionLabel — "■ LABEL" header
// =============================================================================

class TerminalSectionLabel extends StatelessWidget {
  final String label;
  final Color color;

  const TerminalSectionLabel({
    super.key,
    required this.label,
    this.color = TechColors.textPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text(
          '■ ',
          style: TextStyle(color: TechColors.borderActive, fontSize: 10),
        ),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// TerminalDataTable — glass-backed horizontal scrollable DataTable
// =============================================================================

class TerminalDataTable extends StatelessWidget {
  final List<dynamic> headers;
  final dynamic src;
  final Color accent;

  const TerminalDataTable({
    super.key,
    required this.headers,
    required this.src,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final rows = src is List ? src as List : [];
    if (rows.isEmpty) {
      return const Text(
        'Null schema buffer records returned.',
        style: TextStyle(
          color: TechColors.textMuted,
          fontSize: 11,
          fontFamily: 'monospace',
        ),
      );
    }

    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 4),
      padding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(
            TechColors.bgBlack.withValues(alpha: 0.7),
          ),
          headingRowHeight: 34,
          dataRowMinHeight: 28,
          dataRowMaxHeight: 36,
          columnSpacing: 20,
          dividerThickness: 0.5,
          columns: headers
              .map((h) => DataColumn(
            label: Text(
              h.toString(),
              style: TextStyle(
                color: accent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
          ))
              .toList(),
          rows: rows
              .map((row) => DataRow(
            cells: headers.map((h) {
              final val =
              row is Map ? (row[h.toString()] ?? '') : '';
              return DataCell(Text(
                val.toString(),
                style: const TextStyle(
                  color: TechColors.textPrimary,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ));
            }).toList(),
          ))
              .toList(),
        ),
      ),
    );
  }
}

// =============================================================================
// TerminalStatRow — "KEY -> VALUE" metric row
// =============================================================================

class TerminalStatRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const TerminalStatRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: TechColors.textMuted,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
          const Text(
            ' -> ',
            style: TextStyle(
              color: TechColors.borderMuted,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? TechColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}