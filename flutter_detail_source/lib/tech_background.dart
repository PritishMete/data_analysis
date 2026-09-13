// lib/tech_background.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'app_colors.dart';

/// Cyberpunk animated background — slow drifting cyan/blue/green blobs
/// over a deep navy base gradient.
///
/// Wrap with [GlassBackgroundSource] so every [GlassContainer] in the
/// tree samples real colour instead of a synthetic frost tint:
///
/// ```dart
/// LiquidGlassScope(
///   child: Stack(
///     children: [
///       Positioned.fill(
///         child: GlassBackgroundSource(
///           child: const TechAnimatedBackground(),
///         ),
///       ),
///       // ... your UI
///     ],
///   ),
/// )
/// ```
class TechAnimatedBackground extends StatefulWidget {
  const TechAnimatedBackground({super.key});

  @override
  State<TechAnimatedBackground> createState() =>
      _TechAnimatedBackgroundState();
}

class _TechAnimatedBackgroundState extends State<TechAnimatedBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 22),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        GlassAccessibilityData.of(context).reduceMotion;

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF080B14), // near black
            Color(0xFF0F111A), // TechColors.bgBlack
            Color(0xFF0A0E1A), // deep navy
          ],
        ),
      ),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = reduceMotion
              ? 0.0
              : _controller.value * 2 * math.pi;
          return CustomPaint(
            painter: _TechBlobPainter(t: t),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _TechBlobPainter extends CustomPainter {
  const _TechBlobPainter({required this.t});
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    // Three drifting blobs using the cyberpunk palette
    final blobs = [
      (
      TechColors.borderActive, // cyan #00E5FF
      0.50,
      _pos0,
      ),
      (
      TechColors.statusBlue, // blue #3399FF
      0.42,
      _pos1,
      ),
      (
      TechColors.statusGreen, // green #00FF66
      0.38,
      _pos2,
      ),
    ];

    for (final (color, radiusFactor, posFn) in blobs) {
      final center = posFn(size, t);
      final radius = size.shortestSide * radiusFactor;
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.18),
            color.withValues(alpha: 0.0),
          ],
        ).createShader(
            Rect.fromCircle(center: center, radius: radius))
        ..blendMode = BlendMode.plus;
      canvas.drawCircle(center, radius, paint);
    }
  }

  static Offset _pos0(Size s, double t) => Offset(
    s.width * (0.15 + 0.07 * math.sin(t * 0.8)),
    s.height * (0.20 + 0.06 * math.cos(t * 0.7)),
  );

  static Offset _pos1(Size s, double t) => Offset(
    s.width * (0.82 + 0.05 * math.cos(t * 1.1)),
    s.height * (0.65 + 0.07 * math.sin(t * 0.9)),
  );

  static Offset _pos2(Size s, double t) => Offset(
    s.width * (0.45 + 0.09 * math.sin(t * 0.6 + 1.5)),
    s.height * (0.88 + 0.04 * math.cos(t * 1.2)),
  );

  @override
  bool shouldRepaint(covariant _TechBlobPainter old) => old.t != t;
}