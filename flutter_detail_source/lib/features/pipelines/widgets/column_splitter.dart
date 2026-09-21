import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../../../app_colors.dart';
import '../../dashboard/data_screen.dart';

class ColumnSplitter extends StatelessWidget {
  final DataScreenState state;
  const ColumnSplitter({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      shape: const LiquidRoundedSuperellipse(borderRadius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const GlassListTile(
            leading: Icon(CupertinoIcons.textformat_abc_dottedunderline),
            title: Text('Dynamic column boundary splitter'),
            subtitle: Text('Split text into columns using detected delimiters'),
            isLast: false,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('TARGET COLUMN', style: TextStyle(color: TechColors.textMuted, fontSize: 10, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: state.detectedHeaders.contains(state.splitTargetColumn) ? state.splitTargetColumn : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    hintText: 'Select column',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  items: state.detectedHeaders.map((h) => DropdownMenuItem(value: h, child: Text(h, overflow: TextOverflow.ellipsis))).toList(),
                  onChanged: (v) {
                    state.setState(() => state.splitTargetColumn = v);
                    state.triggerDelimiterDetection();
                  },
                ),
                const SizedBox(height: 16),
                const Text('DETECTED DELIMITERS', style: TextStyle(color: TechColors.textMuted, fontSize: 10, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                if (state.isDetectingDelimiters)
                  const LinearProgressIndicator()
                else if (state.detectedDelimiters.isEmpty)
                  const Text('Select a column to detect delimiters.', style: TextStyle(color: TechColors.textMuted, fontSize: 11))
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: state.detectedDelimiters.map((delimiter) {
                      final selected = state.selectedDelimiter == delimiter;
                      final label = delimiter == ' ' ? 'Space' : delimiter == '\t' ? 'Tab' : delimiter;
                      return ChoiceChip(
                        label: Text(label),
                        selected: selected,
                        onSelected: (_) => state.setState(() => state.selectedDelimiter = delimiter),
                      );
                    }).toList(),
                  ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: state.isExecutingSplit || state.selectedDelimiter == null ? null : state.runColumnSplitPipeline,
                    icon: state.isExecutingSplit ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(CupertinoIcons.scissors, size: 16),
                    label: const Text('Split column'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
