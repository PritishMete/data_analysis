// lib/features/dashboard/navigation_tabs.dart
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'data_screen.dart';

/// Same glass preset as `RecommendedGlassSettings.bottomBar` from the
/// liquid_glass_widgets *example app* — that class lives only in the
/// package's example project, not the package itself, so it isn't
/// available here. Inlined directly instead of depending on it.
const _kBottomBarGlassSettings = LiquidGlassSettings(
  thickness: 20,
  blur: 20,
  glassColor: Color(0x26FFFFFF), // ~15% white
  lightAngle: 0.75 * math.pi, // 135° — upper-left, iOS 26 standard
  lightIntensity: 0.7,
  ambientStrength: 0.5,
  saturation: 1.2,
  refractiveIndex: 1.2,
  chromaticAberration: 0.0,
);

/// Plain text pill chips — no icons, no hard outline. Matches the soft
/// tinted-pill look (rounded, tight padding, translucent glass fill).
///
/// Tabs are read straight from `state.views` (id + label) rather than a
/// separately hardcoded list — that's the single source of truth already
/// used by `_buildBody()`'s `selectedView` checks, including the
/// `PIVOT_EDITOR` tab that a hardcoded copy here previously missed.
class NavigationTabs extends StatelessWidget {
  final DataScreenState state;
  const NavigationTabs({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AdaptiveLiquidGlassLayer(
      settings: _kBottomBarGlassSettings,
      quality: GlassQuality.minimal,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SafeArea(
          top: false,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 10),
            itemCount: state.views.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final tab = state.views[index];
              final id = tab['id'] as String;
              final label = tab['label'] as String;
              final isSelected = state.selectedView == id;
              return GlassChip(
                label: label,
                selected: isSelected,
                selectedColor: CupertinoColors.activeGreen.withValues(alpha: 0.35),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                labelStyle: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: isSelected
                      ? CupertinoColors.white
                      : CupertinoColors.label.resolveFrom(context).withValues(alpha: 0.85),
                ),
                onTap: () => state.setState(() => state.selectedView = id),
              );
            },
          ),
        ),
      ),
    );
  }
}