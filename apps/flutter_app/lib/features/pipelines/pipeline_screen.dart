// lib/features/pipelines/pipeline_screen.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../dashboard/data_screen.dart';

import 'widgets/source_router.dart';
import 'widgets/target_attributes.dart';
import 'widgets/conditional_filter.dart';
import 'widgets/column_splitter.dart';
import 'widgets/lookup_builder.dart';
import 'widgets/table_builder.dart';
import 'widgets/color_coding.dart';
import 'widgets/pivot_builder.dart';

class PipelineScreen extends StatelessWidget {
  final DataScreenState state;
  const PipelineScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The native PivotTable has its own source, output, and execution
        // contract. Never let unrelated pipeline options create a copied
        // dataset when the user selects the PivotTable workflow.
        SourceRouter(state: state),
        const SizedBox(height: 20),
        if (kIsWeb) ...[
          GlassCard(
            padding: EdgeInsets.zero,
            shape: const LiquidRoundedSuperellipse(borderRadius: 18),
            child: Column(
              children: [
                GlassListTile(
                  leading: const Icon(CupertinoIcons.table_fill),
                  title: const Text('Native Excel PivotTable'),
                  subtitle: const Text('Build an editable PivotTable from selected fields'),
                  trailing: GlassSwitch(
                    value: state.generatePivotTable,
                    onChanged: (enabled) {
                      state.setState(() {
                        state.generatePivotTable = enabled;
                        if (enabled) {
                          // A manual PivotTable is a standalone operation.
                          // Clear stale transformations so Office.js consumes
                          // the original source range instead of staging a
                          // copied dataset for an unrelated operation.
                          state.deduplicate = false;
                          state.enableFilter = false;
                          state.generateLookup = false;
                        }
                      });
                    },
                  ),
                  isLast: !state.generatePivotTable,
                ),
                if (state.generatePivotTable)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: PivotBuilder(state: state),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        if (!state.generatePivotTable) ...[
          TargetAttributes(state: state),
          const SizedBox(height: 20),
          ConditionalFilter(state: state),
          const SizedBox(height: 20),
          GlassCard(
            padding: EdgeInsets.zero,
            shape: const LiquidRoundedSuperellipse(borderRadius: 18),
            child: Column(
              children: [
                GlassListTile(
                  leading: const Icon(CupertinoIcons.search_circle_fill),
                  title: const Text('Field item extract lookup'),
                  subtitle: const Text('VLOOKUP / HLOOKUP / XLOOKUP against a reference sheet'),
                  trailing: GlassSwitch(
                    value: state.generateLookup,
                    onChanged: (v) => state.setState(() => state.generateLookup = v),
                  ),
                  isLast: !state.generateLookup,
                ),
                if (state.generateLookup)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: LookupBuilder(state: state),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (kIsWeb) ...[
            TableBuilder(state: state),
            const SizedBox(height: 20),
            ColorCoding(state: state),
            const SizedBox(height: 20),
          ],
          if (kIsWeb && state.detectedHeaders.isNotEmpty) ...[
            ColumnSplitter(state: state),
            const SizedBox(height: 20),
          ],
        ],
        // Run action is the fixed bottom FAB in data_screen.dart.
      ],
    );
  }
}
