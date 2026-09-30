import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// Shared physical Liquid Glass treatment used by the floating DataScreen
/// ScanButton and other floating InsightFlow controls.
const double kDockThickness = 24;
const double kDockBlur = 20;
const double kDockChromaticAberration = 0.12;
const double kDockLightIntensity = 0.5;
const double kDockRefractiveIndex = 1.25;
const double kDockSaturation = 1.2;

const double kDockGlowAlpha = 0.5;
const double kDockGlowRadius = 1.2;
const double kDockInteractionScale = 1.08;

LiquidGlassSettings dockGlassSettings({
  required Color glassColor,
}) {
  return LiquidGlassSettings(
    thickness: kDockThickness,
    blur: kDockBlur,
    chromaticAberration: kDockChromaticAberration,
    lightIntensity: kDockLightIntensity,
    refractiveIndex: kDockRefractiveIndex,
    saturation: kDockSaturation,
    glassColor: glassColor,
  );
}

const kDockWhiteGlow = CupertinoColors.white;

