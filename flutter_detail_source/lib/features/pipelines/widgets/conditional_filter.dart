// lib/features/pipelines/widgets/conditional_filter.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../dashboard/data_screen.dart';
import 'shared/glass_picker_sheet.dart';

/// "Conditional Statement Filters" — glass card with a master toggle and,
/// when enabled, glass pickers for column / comparator / values.
class ConditionalFilter extends StatelessWidget {
  final DataScreenState state;
  const ConditionalFilter({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      shape: const LiquidRoundedSuperellipse(borderRadius: 18),
      child: Column(
        children: [
          GlassListTile(
            leading: const Icon(CupertinoIcons.line_horizontal_3_decrease_circle),
            title: const Text('Enable conditional filtering'),
            subtitle: const Text('Only rows matching the rule are kept'),
            trailing: GlassSwitch(
              value: state.enableFilter,
              onChanged: (v) => state.setState(() => state.enableFilter = v),
            ),
            isLast: !state.enableFilter,
          ),
          if (state.enableFilter)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: state.detectedHeaders.isEmpty
                  ? Text(
                'Select a data source to load column names.',
                style: TextStyle(
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  fontSize: 12,
                ),
              )
                  : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GlassFormField(
                    label: 'Column',
                    child: GlassPicker(
                      value: state.selectedFilterColumn,
                      placeholder: 'Select a column',
                      onTap: () => _pickFromList(
                        context: context,
                        title: 'Column',
                        items: state.detectedHeaders,
                        currentValue: state.selectedFilterColumn,
                        onSelected: (v) => state.setState(() => state.selectedFilterColumn = v),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  GlassFormField(
                    label: 'Comparator',
                    child: GlassPicker(
                      value: _labelFor(state.selectedFilterType, state.filterOptions),
                      placeholder: 'Select a comparator',
                      onTap: () => _pickFromOptions(
                        context: context,
                        title: 'Comparator',
                        options: state.filterOptions,
                        currentId: state.selectedFilterType,
                        onSelected: (id) => state.setState(() => state.selectedFilterType = id),
                      ),
                    ),
                  ),
                  if (state.selectedFilterType != 'above_average' &&
                      state.selectedFilterType != 'below_average') ...[
                    const SizedBox(height: 12),
                    GlassFormField(
                      label: 'Value',
                      child: GlassTextField(
                        controller: state.valController1,
                        placeholder: 'Threshold value',
                      ),
                    ),
                    if (state.selectedFilterType == 'between') ...[
                      const SizedBox(height: 12),
                      GlassFormField(
                        label: 'Upper bound',
                        child: GlassTextField(
                          controller: state.valController2,
                          placeholder: 'Upper boundary value',
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  String? _labelFor(String? id, List<Map<String, String>> options) {
    if (id == null) return null;
    for (final opt in options) {
      if (opt['id'] == id) return opt['label'];
    }
    return id;
  }

  Future<void> _pickFromList({
    required BuildContext context,
    required String title,
    required List<String> items,
    required String? currentValue,
    required ValueChanged<String> onSelected,
  }) async {
    final picked = await showGlassPickerSheet<String>(
      context: context,
      title: title,
      items: items,
      itemLabel: (item) => item,
      initialItem: currentValue,
    );
    if (picked != null) onSelected(picked);
  }

  Future<void> _pickFromOptions({
    required BuildContext context,
    required String title,
    required List<Map<String, String>> options,
    required String? currentId,
    required ValueChanged<String> onSelected,
  }) async {
    Map<String, String>? currentOption;
    for (final opt in options) {
      if (opt['id'] == currentId) {
        currentOption = opt;
        break;
      }
    }
    final picked = await showGlassPickerSheet<Map<String, String>>(
      context: context,
      title: title,
      items: options,
      itemLabel: (opt) => opt['label'] ?? '',
      initialItem: currentOption,
    );
    if (picked != null) onSelected(picked['id']!);
  }
}