// lib/tech_background.dart
import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Shared solid application background used across the authenticated app.
///
/// The legacy widget name is retained so existing Liquid Glass composition
/// continues to work without changing foreground widget hierarchies.
class TechAnimatedBackground extends StatelessWidget {
  const TechAnimatedBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(color: kAppBackgroundColor);
  }
}
