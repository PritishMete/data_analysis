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
          // Use the same input as Output Target > Custom sheet name.
          GlassTextField(
            controller: state.pivotSheetNameController,
            placeholder: 'Destination sheet name',
          ),
          const SizedBox(height: 16),
          _heading('PIVOT ROW SEGMENTATION FIELDS (STACKED)', () {
            if (state.detectedHeaders.isNotEmpty) {
              state.setState(() => state.pivotRowFields.add(state.detectedHeaders.first));
            }
          }),
          const SizedBox(height: 4),
          ...List.generate(state.pivotRowFields.length, (index) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Expanded(child: _picker(context, state.pivotRowFields[index], 'Select row axis dimension', state.detectedHeaders,
                (v) => state.setState(() => state.pivotRowFields[index] = v))),
              if (state.pivotRowFields.length > 1) IconButton(
                icon: const Icon(Icons.cancel, color: TechColors.statusRed, size: 18),
                onPressed: () => state.setState(() => state.pivotRowFields.removeAt(index)),
              ),
            ]),
          )),
          const SizedBox(height: 16),
          _heading('PIVOT COLUMN SEGMENTATION FIELDS', () {
            if (state.detectedHeaders.isNotEmpty) {
              state.setState(() => state.pivotColumnFields.add(state.detectedHeaders.first));
            }
          }),
          const SizedBox(height: 4),
          ...List.generate(state.pivotColumnFields.length, (index) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Expanded(child: _picker(context, state.pivotColumnFields[index], 'Select column axis dimension', state.detectedHeaders,
                (v) => state.setState(() => state.pivotColumnFields[index] = v))),
              IconButton(icon: const Icon(Icons.cancel, color: TechColors.statusRed, size: 18),
                onPressed: () => state.setState(() => state.pivotColumnFields.removeAt(index))),
            ]),
          )),
          const SizedBox(height: 16),
          _heading('PIVOT FILTER FIELDS', () {
            if (state.detectedHeaders.isNotEmpty) {
              state.setState(() => state.pivotFilterFields.add(state.detectedHeaders.first));
            }
          }),
          const SizedBox(height: 4),
          ...List.generate(state.pivotFilterFields.length, (index) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Expanded(child: _picker(context, state.pivotFilterFields[index], 'Select report filter field', state.detectedHeaders,
                (v) => state.setState(() => state.pivotFilterFields[index] = v))),
              IconButton(icon: const Icon(Icons.cancel, color: TechColors.statusRed, size: 18),
                onPressed: () => state.setState(() => state.pivotFilterFields.removeAt(index))),
            ]),
          )),
          const SizedBox(height: 16),
          _heading('PIVOT METRIC VALUES DATA COMPILATION', () {
            if (state.detectedHeaders.isNotEmpty) {
              state.setState(() => state.pivotValueFields.add({'field': state.detectedHeaders.last, 'op': 'sum'}));
            }
          }),
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
                child: Row(children: [
                  Expanded(flex: 3, child: _picker(context, entry['field']?.toString(), 'Select accumulation column', state.detectedHeaders,
                    (v) => state.setState(() => state.pivotValueFields[index]['field'] = v))),
                  const SizedBox(width: 6),
                  Expanded(flex: 2, child: _picker(context, entry['op']?.toString(), 'Function',
                    const ['sum', 'average', 'count', 'max', 'min'],
                    (v) => state.setState(() => state.pivotValueFields[index]['op'] = v),
                    itemLabel: (v) => switch (v) {
                      'sum' => 'SUM', 'average' => 'AVG', 'count' => 'COUNT',
                      'max' => 'MAX', 'min' => 'MIN', _ => v.toUpperCase(),
                    })),
                  if (state.pivotValueFields.length > 1) IconButton(
                    icon: const Icon(Icons.delete_outline, color: TechColors.statusRed, size: 18),
                    onPressed: () => state.setState(() => state.pivotValueFields.removeAt(index)),
                  ),
                ]),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _heading(String title, VoidCallback onAdd) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Flexible(child: Text(title, style: const TextStyle(
        color: TechColors.textMuted, fontSize: 10, fontWeight: FontWeight.bold,
      ))),
      const SizedBox(width: 8),
      Tooltip(
        message: 'Add field',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onAdd,
            borderRadius: BorderRadius.circular(7),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Colors.white.withOpacity(0.30), Colors.white.withOpacity(0.09), Colors.white.withOpacity(0.04)],
                ),
                border: Border.all(color: Colors.white.withOpacity(0.35), width: 0.8),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 8, offset: const Offset(0, 3))],
              ),
              child: Stack(alignment: Alignment.center, children: [
                Positioned(top: 2, left: 4, right: 4, child: Container(height: 1,
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.48), borderRadius: BorderRadius.circular(2)))),
                const Icon(Icons.add_rounded, size: 18, color: Colors.white),
              ]),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _picker(BuildContext context, String? value, String placeholder,
    List<String> items, ValueChanged<String> onChanged,
    {String Function(String)? itemLabel}) => GlassPicker(
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
