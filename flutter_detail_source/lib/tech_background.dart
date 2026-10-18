// Canonical animated ambient background used across InsightFlow.
// Keep one source of truth for every screen. Use broad, low-contrast color
// fields rather than distinct circular blobs so the background never reads
// as the old two-bubble animation.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app_colors.dart';

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
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotionPreference();
  }

  @override
  void didUpdateWidget(covariant TechAnimatedBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotionPreference();
  }

  void _syncMotionPreference() {
    if (GlassAccessibilityData.of(context).reduceMotion) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = GlassAccessibilityData.of(context).reduceMotion;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF080B14),
            Color(0xFF0F111A),
            Color(0xFF0A0E1A),
          ],
        ),
      ),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = reduceMotion ? 0.0 : _controller.value * 2 * math.pi;
          return CustomPaint(
            painter: _TechAmbientPainter(t: t),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _TechAmbientPainter extends CustomPainter {
  const _TechAmbientPainter({required this.t});

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    // Oversized, low-opacity radial fields blend together into ambient light.
    // Their edges remain outside most of the viewport, avoiding visible
    // circles or bubble-like shapes on either desktop or mobile.
    final fields = [
      (TechColors.borderActive, 1.05, _position0),
      (TechColors.statusBlue, 0.98, _position1),
      (TechColors.statusGreen, 0.92, _position2),
    ];

    for (final (color, radiusFactor, positionFor) in fields) {
      final center = positionFor(size, t);
      final radius = size.longestSide * radiusFactor;
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.085),
            color.withValues(alpha: 0.025),
            color.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.48, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawRect(Offset.zero & size, paint);
    }
  }

  static Offset _position0(Size size, double t) => Offset(
        size.width * (0.16 + 0.035 * math.sin(t * 0.55)),
        size.height * (0.18 + 0.035 * math.cos(t * 0.50)),
      );

  static Offset _position1(Size size, double t) => Offset(
        size.width * (0.83 + 0.035 * math.cos(t * 0.60)),
        size.height * (0.68 + 0.045 * math.sin(t * 0.52)),
      );

  static Offset _position2(Size size, double t) => Offset(
        size.width * (0.48 + 0.045 * math.sin(t * 0.42 + 1.5)),
        size.height * (0.92 + 0.025 * math.cos(t * 0.65)),
      );

  @override
  bool shouldRepaint(covariant _TechAmbientPainter old) => old.t != t;
}
