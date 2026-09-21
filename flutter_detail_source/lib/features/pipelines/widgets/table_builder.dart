import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../../../app_colors.dart';
import '../../dashboard/data_screen.dart';

class TableBuilder extends StatelessWidget {
  final DataScreenState state;
  const TableBuilder({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      shape: const LiquidRoundedSuperellipse(borderRadius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GlassListTile(
            leading: const Icon(CupertinoIcons.table),
            title: const Text('Build table from single column'),
            subtitle: const Text('WRAPROWS · reshape a single-column dataset'),
            trailing: GlassSwitch(
              value: state.enableTableBuilder,
              onChanged: (v) => state.setState(() => state.enableTableBuilder = v),
            ),
            isLast: !state.enableTableBuilder,
          ),
          if (state.enableTableBuilder)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Specify the source range and output column count. The first wrapped row can be used as headers.', style: TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.4)),
                  const SizedBox(height: 14),
                  _field('SOURCE RANGE (blank = current selection)', state.tableBuilderRangeController, 'e.g. A1:A500'),
                  const SizedBox(height: 12),
                  _field('RESULT COLUMN COUNT', state.tableBuilderColumnCountController, 'e.g. 5', type: TextInputType.number),
                  const SizedBox(height: 12),
                  _field('TARGET SHEET NAME', state.tableBuilderTargetSheetController, 'Wrapped_Table'),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('First row contains headers', style: TextStyle(fontSize: 12)),
                    subtitle: const Text('Bold headers and freeze row 1', style: TextStyle(fontSize: 11)),
                    value: state.tableBuilderHasHeaderRow,
                    onChanged: (v) => state.setState(() => state.tableBuilderHasHeaderRow = v ?? true),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: state.isBuildingTable ? null : state.runTableBuilderPipeline,
                      icon: state.isBuildingTable ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(CupertinoIcons.play_fill, size: 16),
                      label: const Text('Build table'),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _field(String label, TextEditingController controller, String hint, {TextInputType? type}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      TextField(
        controller: controller,
        keyboardType: type,
        style: const TextStyle(fontSize: 12),
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
      ),
    ],
  );
}
