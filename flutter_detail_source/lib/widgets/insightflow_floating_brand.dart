import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../app_colors.dart';

/// Floating InsightFlow brand control shown only inside the authenticated app.
/// It uses the same compact translucent glass treatment as Lockr's floating
/// controls, while retaining the original InsightFlow title width.
class InsightFlowFloatingBrand extends StatelessWidget {
  const InsightFlowFloatingBrand({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassButton.custom(
      onTap: () {},
      enabled: true,
      shape: const LiquidRoundedSuperellipse(borderRadius: 999),
      interactionScale: 1.0,
      stretch: 0.0,
      anchorStretch: false,
      glowColor: TechColors.brandBlue.withValues(alpha: 0.16),
      child: Container(
        width: 180,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: TechColors.panelGlass.tint.withValues(alpha: 0.20),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.16),
            width: 1,
          ),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: [
            Icon(
              Icons.auto_awesome_rounded,
              size: 16,
              color: TechColors.brandBlue,
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
