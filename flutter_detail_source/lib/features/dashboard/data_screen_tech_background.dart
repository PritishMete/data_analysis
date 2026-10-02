// Data Screen-only historical cyberpunk background, adapted from the uploaded
// historical lib/tech_background.dart. Deliberately separate from the shared
// TechAnimatedBackground so other application screens retain their current look.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';

class DataScreenTechBackground extends StatefulWidget {
  const DataScreenTechBackground({super.key});

  @override
  State<DataScreenTechBackground> createState() =>
      _DataScreenTechBackgroundState();
}

class _DataScreenTechBackgroundState extends State<DataScreenTechBackground>
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
  void didUpdateWidget(covariant DataScreenTechBackground oldWidget) {
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
            painter: _DataScreenHistoricalBlobPainter(t: t),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _DataScreenHistoricalBlobPainter extends CustomPainter {
  const _DataScreenHistoricalBlobPainter({required this.t});

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final blobs = [
      (TechColors.borderActive, 0.50, _pos0),
      (TechColors.statusBlue, 0.42, _pos1),
      (TechColors.statusGreen, 0.38, _pos2),
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
        ).createShader(Rect.fromCircle(center: center, radius: radius))
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
  bool shouldRepaint(covariant _DataScreenHistoricalBlobPainter old) =>
      old.t != t;
}
