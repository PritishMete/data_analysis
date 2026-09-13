// lib/features/analysis/widgets/runtime_logs.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../dashboard/data_screen.dart';

class RuntimeLogs extends StatelessWidget {
  final DataScreenState state;
  const RuntimeLogs({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final d = state.analysisData!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader('Logs'),
        GlassCard(
          shape: const LiquidRoundedSuperellipse(borderRadius: 18),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              d['info'] ?? 'No log output yet.',
              style: TextStyle(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
                fontSize: 12,
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
          ),
        ),
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
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}