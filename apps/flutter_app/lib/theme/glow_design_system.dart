import 'package:flutter/material.dart';
import 'glass_theme.dart';

/// Shared glow tokens derived from the existing top-tab glow.
///
/// Keep ambient surfaces quiet and reserve the full reference treatment for
/// active/interactive states. The reference geometry is the tab glow:
/// blur 32, spread 8, opacity 0.6.
class GlowDesignSystem {
  const GlowDesignSystem._();

  static const double blurRadius = 32.0;
  static const double spreadRadius = 8.0;
  static const double activeOpacity = 0.6;
  static const double ambientOpacity = 0.12;

  /// The same brightness-aware white highlight used by the glass theme.
  static Color activeColor(BuildContext context) {
    final isDark = GlassTheme.brightnessOf(context) == Brightness.dark;
    return isDark ? const Color(0x2AFFFFFF) : const Color(0x3DFFFFFF);
  }

  /// A restrained version of the reference glow for non-interactive surfaces.
  static BoxShadow ambientShadow(BuildContext context) {
    return BoxShadow(
      color: activeColor(context).withValues(alpha: ambientOpacity),
      blurRadius: blurRadius,
      spreadRadius: 0,
    );
  }

  /// Full reference geometry for an active control.
  static BoxShadow activeShadow(BuildContext context) {
    return BoxShadow(
      color: activeColor(context).withValues(alpha: activeOpacity),
      blurRadius: blurRadius,
      spreadRadius: spreadRadius,
    );
  }
}
