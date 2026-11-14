// lib/features/dashboard/analyze_fab.dart
import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'data_screen.dart';

/// Shared *shape* values (blur/thickness/lighting) across the dock buttons
/// — lifted from `vault_search_and_bottom_bar.dart`'s `_barSettings`.
const double kDockThickness = 24;
const double kDockBlur = 20;
const double kDockChromaticAberration = 0.12;
const double kDockLightIntensity = 0.5;
const double kDockRefractiveIndex = 1.25;
const double kDockSaturation = 1.2;

/// Circular floating action button that triggers data analysis.
///
/// Kept the original class name (`ScanButton`) since `data_screen.dart`
/// calls it directly by that name.
///
/// Renders a fully opaque solid-colour circle *underneath* the glass shader
/// (rather than relying on a translucent `glassColor` tint alone) — glass
/// alpha blending still lets some backdrop through even at high values,
/// which read as "still transparent" no matter how high the alpha went.
/// The solid layer guarantees an opaque button; the glass layer on top just
/// adds the sheen/specular/refraction look.
class ScanButton extends StatelessWidget {
  final DataScreenState state;
  const ScanButton({super.key, required this.state});

  static const double _size = 56;
  static const Color _accent = Color(0xFF22D3EE);

  bool get _hasSource {
    if (state.dataSourceMode == DataSourceMode.uploadedFile) {
      return state.uploadedFile != null;
    }
    return state.useActiveSelection || state.selectedSourceSheet != null;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _hasSource && !state.isLoading;
    final fillColor = enabled ? _accent : CupertinoColors.systemGrey3;

    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: fillColor.withValues(alpha: 0.5),
            blurRadius: 18,
            spreadRadius: 1,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: SizedBox(
        width: _size,
        height: _size,
        child: Stack(
          children: [
            // ── Opaque base — guarantees the button is fully solid ──────
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: fillColor,
                ),
              ),
            ),
            // ── Glass sheen layer — refraction/specular/interaction on
            // top of the guaranteed-opaque base above ──────────────────
            Positioned.fill(
              child: GlassButton.custom(
                onTap: enabled ? state.analyzeData : () {},
                enabled: enabled,
                width: _size,
                height: _size,
                shape: const LiquidOval(),
                useOwnLayer: true,
                quality: GlassQuality.minimal,
                settings: LiquidGlassSettings(
                  thickness: kDockThickness,
                  blur: kDockBlur,
                  chromaticAberration: kDockChromaticAberration,
                  lightIntensity: kDockLightIntensity,
                  refractiveIndex: kDockRefractiveIndex,
                  saturation: kDockSaturation,
                  // High alpha here just deepens the tint on top of the
                  // opaque base — it's no longer doing the work of hiding
                  // the background by itself.
                  glassColor: fillColor.withValues(alpha: 0.85),
                ),
                glowColor: CupertinoColors.white.withValues(alpha: 0.5),
                glowRadius: 1.2,
                interactionScale: 1.08,
                child: Center(
                  child: state.isLoading
                      ? const CupertinoActivityIndicator(color: CupertinoColors.white)
                      : const Icon(
                    CupertinoIcons.wand_stars,
                    size: 24,
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