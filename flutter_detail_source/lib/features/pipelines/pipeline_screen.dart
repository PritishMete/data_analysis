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

class PipelineScreen extends StatelessWidget {
  final DataScreenState state;
  const PipelineScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Landing: data source (Excel selection / named sheet / upload) ──
        SourceRouter(state: state),
        const SizedBox(height: 20),

        // ── Output Target Object Attributes ──
        TargetAttributes(state: state),
        const SizedBox(height: 20),

        // ── Conditional Statement Filters ──
        ConditionalFilter(state: state),
        const SizedBox(height: 20),

        // ── Enable Field Item Extract Lookup ──
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
          // ── Single-column dump → table (WRAPROWS) ──
          TableBuilder(state: state),
          const SizedBox(height: 20),

          // ── Conditional Colour Formatting ──
          ColorCoding(state: state),
          const SizedBox(height: 20),
        ],

        if (kIsWeb && state.detectedHeaders.isNotEmpty) ...[
          ColumnSplitter(state: state),
          const SizedBox(height: 20),
        ],

        // Run action moved to a fixed bottom FAB (ElectricTaskButton, in
        // data_screen.dart) so it's always reachable without scrolling to
        // the end of this list — no inline button here anymore.
      ],
    );
  }
}