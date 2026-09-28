import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../app_colors.dart';

/// Floating InsightFlow brand control shown only inside the authenticated app.
///
/// This intentionally has no navigation/action: it is a persistent product
/// mark, styled like the compact floating controls used by Lockr.
class InsightFlowFloatingBrand extends StatelessWidget {
  const InsightFlowFloatingBrand({super.key});

  static const _shape = LiquidRoundedSuperellipse(borderRadius: 999);

  @override
  Widget build(BuildContext context) {
    return GlassButton.custom(
      onTap: () {},
      enabled: true,
      shape: _shape,
      interactionScale: 1.01,
      stretch: 0.0,
      anchorStretch: false,
      glowColor: TechColors.brandBlue.withValues(alpha: 0.22),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome_rounded,
              size: 15,
              color: TechColors.brandBlue,
            ),
            SizedBox(width: 8),
            Text(
              'InsightFlow',
              style: TextStyle(
                color: TechColors.textPrimary,
                fontSize: 13,
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
