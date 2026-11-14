// lib/features/pipelines/widgets/deduplicate_picker.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../dashboard/data_screen.dart';

class DeduplicatePicker extends StatelessWidget {
  final DataScreenState state;
  const DeduplicatePicker({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final allSelected = state.deduplicateColumns.length == state.detectedHeaders.length &&
        state.detectedHeaders.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'MATCH KEYS',
                style: TextStyle(
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
              GestureDetector(
                onTap: () => state.setState(() {
                  if (allSelected) {
                    state.deduplicateColumns.clear();
                  } else {
                    state.deduplicateColumns
                      ..clear()
                      ..addAll(state.detectedHeaders);
                  }
                }),
                child: Text(
                  allSelected ? 'Clear' : 'Select All',
                  style: const TextStyle(
                    color: CupertinoColors.activeBlue,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (state.detectedHeaders.isEmpty)
            Text(
              'No columns detected yet.',
              style: TextStyle(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
                fontSize: 12,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: state.detectedHeaders.map((col) {
                final isSel = state.deduplicateColumns.contains(col);
                return GlassChip(
                  label: col,
                  selected: isSel,
                  onTap: () => state.setState(() {
                    isSel ? state.deduplicateColumns.remove(col) : state.deduplicateColumns.add(col);
                  }),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}