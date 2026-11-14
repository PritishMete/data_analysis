// lib/app_colors.dart
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// Cyberpunk design style color tokens utilized throughout the terminal shell.
class TechColors {
  // Shared InsightFlow liquid-glass brand palette.
  static const brandDarkBlue = Color(0xFF123A8C);
  static const brandBlue = Color(0xFF2E6FF2);
  static const brandGraphite = Color(0xFF6E6E76);

  static const bgBlack      = Color(0xFF0F111A);
  static const panelBg      = Color(0xFF141824);
  static const borderActive = brandBlue;
  static const borderMuted  = Color(0xFF22293A);
  static const textPrimary  = Color(0xFFE3E6ED);
  static const textMuted    = Color(0xFF67738C);

  static const statusGreen  = Color(0xFF00FF66);
  static const statusAmber  = Color(0xFFFFB300);
  // Backward-compatible alias used by local pipeline notifications.
  static const statusOrange = statusAmber;
  static const statusRed    = Color(0xFFFF3366);
  static const statusBlue   = Color(0xFF3399FF);

  // ── Shared glass presets ──────────────────────────────────────────────────

  /// Main panel glass — deep navy tint, strong blur.
  static const panelGlass = LiquidGlassSettings(
    thickness: 22,
    blur: 16,
    chromaticAberration: 0.12,
    lightIntensity: 0.45,
    refractiveIndex: 1.2,
    saturation: 1.1,
    glassColor: Color(0x1A123A8C), // dark-blue tint
  );

  /// Inner section glass — lighter, less blur.
  static const sectionGlass = LiquidGlassSettings(
    thickness: 14,
    blur: 8,
    glassColor: Color(0x0F123A8C),
    refractiveIndex: 1.08,
    saturation: 1.05,
  );

  /// Input field glass — minimal, barely-there tint.
  static const fieldGlass = LiquidGlassSettings(
    thickness: 10,
    blur: 4,
    glassColor: Color(0x0A123A8C),
    refractiveIndex: 1.04,
  );
}