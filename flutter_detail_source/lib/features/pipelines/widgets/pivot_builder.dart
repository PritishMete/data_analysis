// lib/features/pipelines/widgets/pivot_builder.dart
import 'package:flutter/material.dart';
import '../../../app_colors.dart';
import '../../dashboard/data_screen.dart';

class PivotBuilder extends StatelessWidget {
  final DataScreenState state;
  const PivotBuilder({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _styledTextField(
            controller: state.pivotSheetNameController,
            hint: "Pivot Destination Worksheet Name",
          ),
          const SizedBox(height: 16),

          // ── MULTIPLE ROWS SECTION ──
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildItemLabel("PIVOT ROW SEGMENTATION FIELDS (STACKED)"),
              IconButton(
                icon: const Icon(Icons.add_box, color: TechColors.borderActive, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  if (state.detectedHeaders.isNotEmpty) {
                    state.setState(() => state.pivotRowFields.add(state.detectedHeaders.first));
                  }
                },
              )
            ],
          ),
          const SizedBox(height: 4),
          ...List.generate(state.pivotRowFields.length, (index) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: _styledDropdown<String>(
                      value: state.pivotRowFields[index],
                      hint: "Select row axis dimension",
                      items: state.detectedHeaders
                          .map((h) => DropdownMenuItem(
                          value: h,
                          child: Text(h, style: const TextStyle(fontSize: 12, color: Colors.white))))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          state.setState(() => state.pivotRowFields[index] = v);
                        }
                      },
                    ),
                  ),
                  if (state.pivotRowFields.length > 1)
                    IconButton(
                      icon: const Icon(Icons.cancel, color: TechColors.statusRed, size: 18),
                      onPressed: () => state.setState(() => state.pivotRowFields.removeAt(index)),
                    ),
                ],
              ),
            );
          }),

          const SizedBox(height: 16),

          // ── MULTIPLE VALUES & AGGREGATIONS SECTION ──
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildItemLabel("PIVOT METRIC VALUES DATA COMPILATION"),
              IconButton(
                icon: const Icon(Icons.add_box, color: TechColors.borderActive, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  if (state.detectedHeaders.isNotEmpty) {
                    state.setState(() => state.pivotValueFields.add({"field": state.detectedHeaders.last, "op": "sum"}));
                  }
                },
              )
            ],
          ),
          const SizedBox(height: 4),
          ...List.generate(state.pivotValueFields.length, (index) {
            final entry = state.pivotValueFields[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: TechColors.panelBg.withOpacity(0.5),
                  border: Border.all(color: TechColors.borderMuted),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _styledDropdown<String>(
                        value: entry["field"],
                        hint: "Select accumulation column",
                        items: state.detectedHeaders
                            .map((h) => DropdownMenuItem(
                            value: h,
                            child: Text(h, style: const TextStyle(fontSize: 11, color: Colors.white))))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) {
                            state.setState(() => state.pivotValueFields[index]["field"] = v);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      flex: 2,
                      child: _styledDropdown<String>(
                        value: entry["op"],
                        hint: "Function",
                        items: const [
                          DropdownMenuItem(value: "sum", child: Text("SUM", style: TextStyle(fontSize: 11, color: Colors.white))),
                          DropdownMenuItem(value: "average", child: Text("AVG", style: TextStyle(fontSize: 11, color: Colors.white))),
                          DropdownMenuItem(value: "count", child: Text("COUNT", style: TextStyle(fontSize: 11, color: Colors.white))),
                          DropdownMenuItem(value: "max", child: Text("MAX", style: TextStyle(fontSize: 11, color: Colors.white))),
                          DropdownMenuItem(value: "min", child: Text("MIN", style: TextStyle(fontSize: 11, color: Colors.white))),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            state.setState(() => state.pivotValueFields[index]["op"] = v);
                          }
                        },
                      ),
                    ),
                    if (state.pivotValueFields.length > 1)
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: TechColors.statusRed, size: 18),
                        onPressed: () => state.setState(() => state.pivotValueFields.removeAt(index)),
                      ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildItemLabel(String label) {
    return Text(label, style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontWeight: FontWeight.bold));
  }

  Widget _styledDropdown<T>({
    required T? value,
    required String hint,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
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

  Widget _styledTextField({
    required TextEditingController controller,
    required String hint,
  }) {
    return SizedBox(
      height: 36,
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white, fontSize: 12),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: TechColors.textMuted, fontSize: 11),
          filled: true,
          fillColor: TechColors.bgBlack,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: TechColors.borderMuted)),
          focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: TechColors.borderActive)),
        ),
      ),
    );
  }
}