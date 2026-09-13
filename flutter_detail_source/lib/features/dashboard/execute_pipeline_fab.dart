// lib/features/dashboard/execute_pipeline_fab.dart
import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'analyze_fab.dart'
    show
    kDockThickness,
    kDockBlur,
    kDockChromaticAberration,
    kDockLightIntensity,
    kDockRefractiveIndex,
    kDockSaturation;
import 'data_screen.dart';

/// Wide glass pill that runs the configured transformation pipeline.
///
/// Same opaque-base + glass-sheen-on-top approach as [ScanButton] — a solid
/// colour fill guarantees this reads as a fully opaque button, with the
/// glass layer only adding shine/refraction on top rather than being
/// responsible for hiding the background itself.
class ElectricTaskButton extends StatelessWidget {
  final DataScreenState state;
  const ElectricTaskButton({super.key, required this.state});

  static const double _height = 56;
  static const Color _accent = Color(0xFF64748B); // neutral slate

  @override
  Widget build(BuildContext context) {
    final enabled = !state.pipelineProcessing;
    final fillColor = enabled ? _accent : CupertinoColors.systemGrey3;
    final radius = BorderRadius.circular(_height / 2);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.black.withValues(alpha: 0.4),
            blurRadius: 16,
            spreadRadius: 0,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: SizedBox(
        height: _height,
        child: Stack(
          children: [
            // ── Opaque base ──────────────────────────────────────────────
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  color: fillColor,
                ),
              ),
            ),
            // ── Glass sheen layer on top ─────────────────────────────────
            Positioned.fill(
              child: GlassButton.custom(
                onTap: enabled ? state.runTransformationPipeline : () {},
                enabled: enabled,
                height: _height,
                width: double.infinity,
                shape: LiquidRoundedSuperellipse(borderRadius: _height / 2),
                useOwnLayer: true,
                quality: GlassQuality.minimal,
                settings: LiquidGlassSettings(
                  thickness: kDockThickness,
                  blur: kDockBlur,
                  chromaticAberration: kDockChromaticAberration,
                  lightIntensity: kDockLightIntensity,
                  refractiveIndex: kDockRefractiveIndex,
                  saturation: kDockSaturation,
                  glassColor: fillColor.withValues(alpha: 0.85),
                ),
                glowColor: CupertinoColors.white.withValues(alpha: 0.45),
                glowRadius: 1.0,
                interactionScale: 1.02,
                child: Center(
                  child: state.pipelineProcessing
                      ? const CupertinoActivityIndicator(color: CupertinoColors.white)
                      : const Icon(
                    CupertinoIcons.bolt_fill,
                    size: 22,
                    color: CupertinoColors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}