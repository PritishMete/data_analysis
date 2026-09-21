// lib/features/pipelines/widgets/pivot_builder.dart
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../../../app_colors.dart';
import '../../dashboard/data_screen.dart';
import 'shared/glass_picker_sheet.dart';

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
                    child: _glassFieldPicker(
                      context: context,
                      value: state.pivotRowFields[index],
                      placeholder: "Select row axis dimension",
                      items: state.detectedHeaders,
                      onChanged: (v) {
                        state.setState(() => state.pivotRowFields[index] = v);
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

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildItemLabel("PIVOT COLUMN SEGMENTATION FIELDS"),
              IconButton(
                icon: const Icon(Icons.add_box, color: TechColors.borderActive, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  if (state.detectedHeaders.isNotEmpty) {
                    state.setState(() => state.pivotColumnFields.add(state.detectedHeaders.first));
                  }
                },
              )
            ],
          ),
          const SizedBox(height: 4),
          ...List.generate(state.pivotColumnFields.length, (index) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: _glassFieldPicker(
                      context: context,
                      value: state.pivotColumnFields[index],
                      placeholder: "Select column axis dimension",
                      items: state.detectedHeaders,
                      onChanged: (v) {
                        state.setState(() => state.pivotColumnFields[index] = v);
                      },
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.cancel, color: TechColors.statusRed, size: 18),
                    onPressed: () => state.setState(() => state.pivotColumnFields.removeAt(index)),
                  ),
                ],
              ),
            );
          }),

          const SizedBox(height: 16),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildItemLabel("PIVOT FILTER FIELDS"),
              IconButton(
                icon: const Icon(Icons.add_box, color: TechColors.borderActive, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  if (state.detectedHeaders.isNotEmpty) {
                    state.setState(() => state.pivotFilterFields.add(state.detectedHeaders.first));
                  }
                },
              )
            ],
          ),
          const SizedBox(height: 4),
          ...List.generate(state.pivotFilterFields.length, (index) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: _glassFieldPicker(
                      context: context,
                      value: state.pivotFilterFields[index],
                      placeholder: "Select report filter field",
                      items: state.detectedHeaders,
                      onChanged: (v) {
                        state.setState(() => state.pivotFilterFields[index] = v);
                      },
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.cancel, color: TechColors.statusRed, size: 18),
                    onPressed: () => state.setState(() => state.pivotFilterFields.removeAt(index)),
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
                      child: _glassFieldPicker(
                        context: context,
                        value: entry["field"]?.toString(),
                        placeholder: "Select accumulation column",
                        items: state.detectedHeaders,
                        compact: true,
                        onChanged: (v) {
                          state.setState(() => state.pivotValueFields[index]["field"] = v);
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      flex: 2,
                      child: _glassFieldPicker(
                        context: context,
                        value: entry["op"]?.toString(),
                        placeholder: "Function",
                        items: const ["sum", "average", "count", "max", "min"],
                        itemLabel: (v) => switch (v) {
                          "sum" => "SUM",
                          "average" => "AVG",
                          "count" => "COUNT",
                          "max" => "MAX",
                          "min" => "MIN",
                          _ => v.toUpperCase(),
                        },
                        compact: true,
                        onChanged: (v) {
                          state.setState(() => state.pivotValueFields[index]["op"] = v);
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

  Widget _glassFieldPicker({
    required BuildContext context,
    required String? value,
    required String placeholder,
    required List<String> items,
    required ValueChanged<String> onChanged,
    String Function(String value)? itemLabel,
    bool compact = false,
  }) {
    return GlassPicker(
      value: value,
      placeholder: placeholder,
      icon: const Icon(Icons.keyboard_arrow_down_rounded),
      onTap: () async {
        final picked = await showGlassPickerSheet<String>(
          context: context,
          title: placeholder,
          items: items,
          itemLabel: itemLabel ?? (item) => item,
          initialItem: value,
        );
        if (picked != null) onChanged(picked);
      },
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
