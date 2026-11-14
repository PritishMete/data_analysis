import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../../../app_colors.dart';
import '../../dashboard/data_screen.dart';
import 'shared/glass_picker_sheet.dart';

class ColumnSplitter extends StatelessWidget {
  final DataScreenState state;
  const ColumnSplitter({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final selectedColumn =
        state.detectedHeaders.contains(state.splitTargetColumn)
            ? state.splitTargetColumn
            : null;

    return GlassCard(
      padding: EdgeInsets.zero,
      shape: const LiquidRoundedSuperellipse(borderRadius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const GlassListTile(
            leading: Icon(CupertinoIcons.textformat_abc_dottedunderline),
            title: Text('Dynamic column boundary splitter'),
            subtitle: Text(
              'Split text into columns using detected delimiters',
            ),
            isLast: false,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GlassFormField(
                  label: 'Target column',
                  child: GlassPicker(
                    value: selectedColumn,
                    placeholder: 'Select column',
                    icon: const Icon(CupertinoIcons.chevron_down),
                    onTap: state.detectedHeaders.isEmpty
                        ? null
                        : () async {
                            final picked =
                                await showGlassPickerSheet<String>(
                              context: context,
                              title: 'Select Target Column',
                              items: state.detectedHeaders,
                              itemLabel: (item) => item,
                              initialItem: selectedColumn,
                            );
                            if (picked == null) return;
                            state.setState(
                              () => state.splitTargetColumn = picked,
                            );
                            await state.triggerDelimiterDetection();
                          },
                  ),
                ),
                const SizedBox(height: 16),
                GlassFormField(
                  label: 'Detected delimiters',
                  child: state.isDetectingDelimiters
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              CupertinoActivityIndicator(),
                              SizedBox(width: 10),
                              Text(
                                'Detecting delimiters…',
                                style: TextStyle(
                                  color: TechColors.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        )
                      : state.detectedDelimiters.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                'Select a column to detect delimiters.',
                                style: TextStyle(
                                  color: TechColors.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                            )
                          : Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: state.detectedDelimiters.map((delimiter) {
                                final selected =
                                    state.selectedDelimiter == delimiter;
                                final label = delimiter == ' '
                                    ? 'Space'
                                    : delimiter == '\t'
                                        ? 'Tab'
                                        : delimiter;
                                return GlassChip(
                                  label: label,
                                  selected: selected,
                                  onTap: () => state.setState(
                                    () => state.selectedDelimiter = delimiter,
                                  ),
                                );
                              }).toList(),
                            ),
                ),
                const SizedBox(height: 16),
                GlassButton(
                  onTap: state.isExecutingSplit ||
                          state.selectedDelimiter == null
                      ? () {}
                      : state.runColumnSplitPipeline,
                  enabled: !state.isExecutingSplit &&
                      state.selectedDelimiter != null,
                  width: double.infinity,
                  height: 46,
                  shape: const LiquidRoundedSuperellipse(borderRadius: 14),
                  icon: state.isExecutingSplit
                      ? const CupertinoActivityIndicator()
                      : const Icon(CupertinoIcons.scissors, size: 16),
                  label: state.isExecutingSplit
                      ? 'Splitting…'
                      : 'Split column',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
