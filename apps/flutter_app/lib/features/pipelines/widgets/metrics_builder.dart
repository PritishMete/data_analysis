// lib/features/pipelines/widgets/metrics_builder.dart
import 'package:flutter/material.dart';
import '../../../app_colors.dart';
import '../../dashboard/data_screen.dart';

class MetricsBuilder extends StatelessWidget {
  final DataScreenState state;
  const MetricsBuilder({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final bool hasHeaders = state.detectedHeaders.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _styledTextField(
            controller: state.metricsSheetNameController,
            hint: "Metrics Layer Sheet Identifier Name",
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("TARGET METRICS ATTRIBUTES",
                  style: TextStyle(color: TechColors.textMuted, fontSize: 11, fontWeight: FontWeight.bold)),
              InkWell(
                onTap: () {
                  state.setState(() {
                    if (state.metricsColumns.length == state.detectedHeaders.length) {
                      state.metricsColumns.clear();
                    } else {
                      state.metricsColumns
                        ..clear()
                        ..addAll(state.detectedHeaders);
                    }
                  });
                },
                child: Text(
                  state.metricsColumns.length == state.detectedHeaders.length && state.detectedHeaders.isNotEmpty
                      ? "[CLEAR]"
                      : "[SELECT ALL]",
                  style: const TextStyle(color: TechColors.borderActive, fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!hasHeaders)
            const Text("Resolve compilation indexes to map header attributes.",
                style: TextStyle(color: TechColors.textMuted, fontSize: 11))
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: state.detectedHeaders.map((col) {
                final isSel = state.metricsColumns.contains(col);
                return InkWell(
                  onTap: () {
                    state.setState(() {
                      if (isSel) {
                        state.metricsColumns.remove(col);
                      } else {
                        state.metricsColumns.add(col);
                      }
                    });
                  },
                  child: _chipBadge(col, isSel),
                );
              }).toList(),
            ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("COMPUTE PIPELINE TRANSLATIONS",
                  style: TextStyle(color: TechColors.textMuted, fontSize: 11, fontWeight: FontWeight.bold)),
              InkWell(
                onTap: () {
                  state.setState(() {
                    if (state.metricsOps.length == kAllMetricOps.length) {
                      state.metricsOps.clear();
                    } else {
                      state.metricsOps
                        ..clear()
                        ..addAll(kAllMetricOps.map((m) => m['id'] as String));
                    }
                  });
                },
                child: Text(
                  state.metricsOps.length == kAllMetricOps.length ? "[CLEAR]" : "[SELECT ALL]",
                  style: const TextStyle(color: TechColors.borderActive, fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: kAllMetricOps.map((op) {
              final id = op['id'] as String;
              final lbl = op['label'] as String;
              final isSel = state.metricsOps.contains(id);
              return InkWell(
                onTap: () {
                  state.setState(() {
                    if (isSel) {
                      state.metricsOps.remove(id);
                    } else {
                      state.metricsOps.add(id);
                    }
                  });
                },
                child: _chipBadge(lbl, isSel),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _chipBadge(String label, bool selected) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: selected ? TechColors.borderMuted : Colors.transparent,
        border: Border.all(
            color: selected ? TechColors.borderActive : TechColors.borderMuted),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(label, style: TextStyle(color: selected ? TechColors.borderActive : TechColors.textMuted, fontSize: 11)),
    );
  }

  Widget _styledTextField({
    required TextEditingController controller,
    required String hint,
  }) {
    return SizedBox(
      height: 36,
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white, fontSize: 12),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: TechColors.textMuted, fontSize: 11),
          filled: true,
          fillColor: TechColors.bgBlack,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: TechColors.borderMuted)),
          focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: TechColors.borderActive)),
        ),
      ),
    );
  }
}