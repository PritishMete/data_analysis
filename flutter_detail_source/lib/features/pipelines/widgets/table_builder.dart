// lib/features/pipelines/widgets/table_builder.dart
import 'package:flutter/material.dart';

import '../../../app_colors.dart';
import '../../dashboard/data_screen.dart';

/// UI for the "all data + headers dumped in one column" scenario.
/// Lets the user point at a single-column range and a result column
/// count, then runs `=WRAPROWS(range, columnCount)` to reshape it
/// into a proper 2D table on a target sheet.
class TableBuilder extends StatelessWidget {
  final DataScreenState state;
  const TableBuilder({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TechColors.panelBg,
        border: Border.all(color: TechColors.borderMuted),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Switch(
                value: state.enableTableBuilder,
                activeColor: TechColors.borderActive,
                onChanged: (v) => state.setState(() => state.enableTableBuilder = v),
              ),
              const Expanded(
                child: Text(
                  "BUILD TABLE FROM SINGLE COLUMN (WRAPROWS)",
                  style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          if (state.enableTableBuilder) ...[
            const SizedBox(height: 4),
            const Text(
              "Use this when an entire table (headers + data) has been dumped into one column. "
                  "Specify the source range and how many columns the result should wrap into — the "
                  "first row of the wrapped output will be your headers.",
              style: TextStyle(color: TechColors.textMuted, fontSize: 10, height: 1.4),
            ),
            const SizedBox(height: 10),
            _buildLabeledField(
              label: "SOURCE RANGE (blank = current selection)",
              controller: state.tableBuilderRangeController,
              hint: "e.g. A1:A500",
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _buildLabeledField(
                    label: "RESULT COLUMN COUNT",
                    controller: state.tableBuilderColumnCountController,
                    hint: "e.g. 5",
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _buildLabeledField(
                    label: "TARGET SHEET NAME",
                    controller: state.tableBuilderTargetSheetController,
                    hint: "Wrapped_Table",
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Checkbox(
                  value: state.tableBuilderHasHeaderRow,
                  activeColor: TechColors.borderActive,
                  onChanged: (v) => state.setState(() => state.tableBuilderHasHeaderRow = v ?? true),
                ),
                const Expanded(
                  child: Text(
                    "First wrapped row contains headers (bold + freeze row 1)",
                    style: TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 36,
              child: ElevatedButton(
                onPressed: state.isBuildingTable ? null : state.runTableBuilderPipeline,
                style: ElevatedButton.styleFrom(
                  backgroundColor: state.isBuildingTable ? TechColors.panelBg : TechColors.borderActive,
                  foregroundColor: Colors.black,
                ),
                child: state.isBuildingTable
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text("RUN WRAPROWS TABLE BUILD", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLabeledField({
    required String label,
    required TextEditingController controller,
    String? hint,
    TextInputType? keyboardType,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: TechColors.textMuted, fontSize: 9, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: TechColors.textMuted, fontSize: 11),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: TechColors.borderMuted)),
            focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: TechColors.borderActive)),
          ),
        ),
      ],
    );
  }
}