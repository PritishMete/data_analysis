// lib/tech_background.dart
import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Shared dark background used across the authenticated app.
///
/// The ambient glowing bubbles have been intentionally removed so every
/// screen uses a clean, static background without decorative light blobs.
class TechAnimatedBackground extends StatelessWidget {
  const TechAnimatedBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
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
    );
  }
}
