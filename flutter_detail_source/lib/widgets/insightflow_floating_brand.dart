import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../app_colors.dart';

/// Floating authenticated-app brand.
///
/// The glass treatment intentionally mirrors Lockr's floating/sign-out
/// control: the same LiquidGlassSettings, standalone layer, and standard
/// quality are used instead of a painted/tinted BoxDecoration.
class InsightFlowFloatingBrand extends StatelessWidget {
  const InsightFlowFloatingBrand({super.key});

/// Shared glass material used by the floating InsightFlow brand and
/// the ManagementShell header. Keep these physical settings as the source
/// of truth; the two surfaces intentionally retain different geometries.
const kInsightFlowFloatingBrandGlassSettings = LiquidGlassSettings(
  thickness: 14,
  blur: 8,
  glassColor: Color(0x0FFFFFFF),
  refractiveIndex: 1.05,
);

  @override
  Widget build(BuildContext context) {
    return GlassButton.custom(
      onTap: () {},
      enabled: true,
      width: 180,
      height: 56,
      shape: const LiquidRoundedSuperellipse(borderRadius: 999),
      useOwnLayer: true,
      settings: kInsightFlowFloatingBrandGlassSettings,
      quality: GlassQuality.standard,
      interactionScale: 1.0,
      stretch: 0.0,
      anchorStretch: false,
      glowColor: TechColors.borderActive.withValues(alpha: 0.16),
      label: 'InsightFlow',
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: [
            Icon(
              Icons.auto_awesome_rounded,
              size: 16,
              color: TechColors.borderActive,
            ),
            SizedBox(width: 9),
            Text(
              'InsightFlow',
              style: TextStyle(
                color: TechColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps the brand visible over every verified authenticated-app route.
///
/// Login/signup are outside this shell, so their UI is untouched.
class AuthenticatedBrandShell extends StatelessWidget {
  const AuthenticatedBrandShell({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        const Positioned(
          top: 12,
          right: 18,
          child: SafeArea(
            child: InsightFlowFloatingBrand(),
          ),
        ),
      ],
    );
  }
}
