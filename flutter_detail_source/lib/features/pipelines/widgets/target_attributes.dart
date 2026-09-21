// lib/features/pipelines/widgets/target_attributes.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../dashboard/data_screen.dart';
import 'pivot_builder.dart';
import 'deduplicate_picker.dart';

/// "Output Target Object Attributes" — a grouped glass section of toggles
/// controlling how the destination sheet is created and shaped.
class TargetAttributes extends StatelessWidget {
  final DataScreenState state;
  const TargetAttributes({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlassGroupedSection(
          header: const _SectionHeader('Output Target Object Attributes'),
          children: [
            GlassListTile(
              leading: const Icon(CupertinoIcons.doc_on_doc),
              title: const Text('New destination sheet'),
              subtitle: const Text('Write results to a dedicated sheet'),
              trailing: GlassSwitch(
                value: state.createNewSheet,
                onChanged: (v) => state.setState(() => state.createNewSheet = v),
              ),
            ),
            if (state.createNewSheet) ...[
              GlassListTile(
                leading: const Icon(CupertinoIcons.pencil),
                title: const Text('Custom sheet name'),
                trailing: GlassSwitch(
                  value: state.useCustomTargetName,
                  onChanged: (v) => state.setState(() => state.useCustomTargetName = v),
                ),
              ),
              if (state.useCustomTargetName)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: GlassTextField(
                    controller: state.targetSheetNameController,
                    placeholder: 'Destination sheet name',
                  ),
                ),
            ],
            GlassListTile(
              leading: const Icon(CupertinoIcons.rectangle_grid_1x2),
              title: const Text('Freeze header row'),
              subtitle: const Text('Row 1 becomes the column schema'),
              trailing: GlassSwitch(
                value: state.freezeHeaderRow,
                onChanged: (v) => state.setState(() {
                  state.freezeHeaderRow = v;
                  if (!v) state.enableAutoFilter = false;
                }),
              ),
            ),
            IgnorePointer(
              ignoring: !state.freezeHeaderRow,
              child: Opacity(
                opacity: state.freezeHeaderRow ? 1.0 : 0.4,
                child: GlassListTile(
                  leading: const Icon(CupertinoIcons.slider_horizontal_3),
                  title: const Text('Auto-filter dropdowns'),
                  subtitle: const Text('Adds header filter controls'),
                  trailing: GlassSwitch(
                    value: state.enableAutoFilter,
                    onChanged: (v) => state.setState(() => state.enableAutoFilter = v),
                  ),
                ),
              ),
            ),
            GlassListTile(
              leading: const Icon(CupertinoIcons.square_grid_2x2),
              title: const Text('Generate native PivotTable'),
              subtitle: const Text('Create a real editable Excel PivotTable'),
              trailing: GlassSwitch(
                value: state.generatePivotTable,
                onChanged: (v) => state.setState(() {
                  state.generatePivotTable = v;
                  if (!v) {
                    state.pivotRowFields.clear();
                    state.pivotColumnFields.clear();
                    state.pivotFilterFields.clear();
                    state.pivotValueFields.clear();
                  } else if (state.pivotRowFields.isEmpty &&
                      state.detectedHeaders.isNotEmpty) {
                    state.pivotRowFields.add(state.detectedHeaders.first);
                  }
                  if (v &&
                      state.pivotValueFields.isEmpty &&
                      state.detectedHeaders.isNotEmpty) {
                    state.pivotValueFields.add({
                      'field': state.detectedHeaders.last,
                      'op': 'sum',
                    });
                  }
                }),
              ),
            ),
            GlassListTile(
              leading: const Icon(CupertinoIcons.square_stack_3d_down_right),
              title: const Text('Remove duplicate rows'),
              trailing: GlassSwitch(
                value: state.deduplicate,
                onChanged: (v) => state.setState(() {
                  state.deduplicate = v;
                  if (!v) state.deduplicateColumns.clear();
                }),
              ),
              isLast: !(state.generatePivotTable || state.deduplicate),
            ),
          ],
        ),

        if (state.generatePivotTable) ...[
          const SizedBox(height: 12),
          GlassCard(
            padding: EdgeInsets.zero,
            shape: const LiquidRoundedSuperellipse(borderRadius: 16),
            child: PivotBuilder(state: state),
          ),
        ],
        if (state.deduplicate) ...[
          const SizedBox(height: 12),
          GlassCard(
            padding: EdgeInsets.zero,
            shape: const LiquidRoundedSuperellipse(borderRadius: 16),
            child: DeduplicatePicker(state: state),
          ),
        ],
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
      padding: const EdgeInsets.only(left: 16, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}