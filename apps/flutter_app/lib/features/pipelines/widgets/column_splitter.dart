// lib/features/pipelines/widgets/column_splitter.dart
import 'package:flutter/material.dart';
import '../../../app_colors.dart';
import '../../dashboard/data_screen.dart';

class ColumnSplitter extends StatelessWidget {
  final DataScreenState state;
  const ColumnSplitter({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text("■ ", style: TextStyle(color: TechColors.borderActive, fontSize: 10)),
            Text(
              "DYNAMIC COLUMN BOUNDARY SPLITTER".toUpperCase(),
              style: const TextStyle(color: TechColors.textPrimary, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: TechColors.panelBg,
            border: Border.all(color: TechColors.borderMuted),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildItemLabel("CHOOSE TARGET COLUMN FIELD"),
              const SizedBox(height: 6),
              _styledDropdown<String>(
                value: state.splitTargetColumn,
                hint: "Select column operand",
                items: state.detectedHeaders
                    .map((h) => DropdownMenuItem(
                    value: h,
                    child: Text(h, style: const TextStyle(fontSize: 12, color: Colors.white))))
                    .toList(),
                onChanged: (v) {
                  state.setState(() => state.splitTargetColumn = v);
                  state.triggerDelimiterDetection();
                },
              ),
              const SizedBox(height: 14),
              _buildItemLabel("DISCOVERED AUTODETECTED DELIMITERS"),
              const SizedBox(height: 6),
              if (state.isDetectingDelimiters)
                const LinearProgressIndicator(color: TechColors.borderActive, backgroundColor: Colors.transparent)
              else if (state.detectedDelimiters.isEmpty)
                const Text("No operational layout map delimiters detected inside text samples.",
                    style: TextStyle(color: TechColors.textMuted, fontSize: 11))
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: state.detectedDelimiters.map((del) {
                    final isSel = state.selectedDelimiter == del;
                    String label = del;
                    if (del == ' ')  label = '[SPACE]';
                    if (del == '\t') label = '[TAB]';
                    return InkWell(
                      onTap: () => state.setState(() => state.selectedDelimiter = del),
                      child: _chipBadge(label, isSel),
                    );
                  }).toList(),
                ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 38,
                child: ElevatedButton(
                  onPressed: (state.isExecutingSplit || state.selectedDelimiter == null)
                      ? null
                      : state.runColumnSplitPipeline,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: TechColors.statusBlue,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: TechColors.panelBg,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
                  ),
                  child: state.isExecutingSplit
                      ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(color: TechColors.statusAmber, strokeWidth: 2))
                      : const Text("EXECUTE ATOMIC COLUMN ATOMIZATION",
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildItemLabel(String label) {
    return Text(label, style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontWeight: FontWeight.bold));
  }

  Widget _chipBadge(String label, bool selected) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: selected ? TechColors.borderMuted : Colors.transparent,
        border: Border.all(
            color: selected ? TechColors.borderActive : TechColors.borderMuted),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(label, style: TextStyle(color: selected ? TechColors.borderActive : TechColors.textMuted, fontSize: 11)),
    );
  }

  Widget _styledDropdown<T>({
    required T? value,
    required String hint,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: TechColors.bgBlack,
        border: Border.all(color: TechColors.borderMuted),
        borderRadius: BorderRadius.circular(2),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          hint: Text(hint, style: const TextStyle(color: TechColors.textMuted, fontSize: 11)),
          dropdownColor: TechColors.panelBg,
          isExpanded: true,
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}