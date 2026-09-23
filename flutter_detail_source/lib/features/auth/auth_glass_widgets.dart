import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../tech_background.dart';

/// Authentication composition built from the same glass surfaces used by the
/// Native Excel PivotTable / Pipeline UI.
///
/// This widget intentionally does not define a second glass renderer or a
/// second palette. The card, list row, fields, buttons and background all come
/// from the shared InsightFlow liquid-glass library and its app-wide theme.
class AuthGlassScaffold extends StatelessWidget {
  const AuthGlassScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      background: const TechAnimatedBackground(),
      edgeFade: false,
      body: SafeArea(
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: GlassCard(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                shape: const LiquidRoundedSuperellipse(borderRadius: 16),
                child: Row(
                  children: [
                    const Icon(
                      Icons.terminal,
                      color: TechColors.borderActive,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'InsightFlow',
                      style: TextStyle(
                        color: TechColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.only(top: 61),
                child: LayoutBuilder(
        builder: (context, constraints) {
          final horizontalPadding = constraints.hasBoundedWidth &&
                  constraints.maxWidth < 420
              ? 8.0
              : 16.0;
          final verticalPadding = constraints.hasBoundedHeight &&
                  constraints.maxHeight < 620
              ? 12.0
              : 20.0;
          final minViewportHeight = constraints.hasBoundedHeight
              ? (constraints.maxHeight - verticalPadding * 2)
                  .clamp(0.0, double.infinity)
              : 0.0;

          final card = ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SizedBox(
              width: double.infinity,
              child: GlassCard(
                padding: EdgeInsets.zero,
                shape: const LiquidRoundedSuperellipse(borderRadius: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GlassListTile(
                      leading: const Icon(CupertinoIcons.lock_shield_fill),
                      title: Text(title),
                      subtitle: Text(subtitle),
                      isLast: false,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: children,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );

          // Fill the available viewport first so the auth card is genuinely
          // centered on short, tall, narrow and wide screens. When the card
          // is taller than the viewport (notably Signup in a narrow task
          // pane), the same scroll view naturally becomes vertically
          // scrollable instead of overflowing.
          return SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: verticalPadding,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minViewportHeight),
              child: Center(child: card),
            ),
          );
        },
,
              ),
            ),
          ],
        ),
      ),),
    );
  }
}

/// Small composition-only label used above authentication inputs.
///
/// The input itself remains the shared [GlassTextField] /
/// [GlassPasswordField]; this only supplies the compact uppercase hierarchy
/// already used by the Pipeline UI.
class AuthGlassFieldLabel extends StatelessWidget {
  const AuthGlassFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Status feedback kept as composition only; the visual surface is the shared
/// [GlassContainer] component.
class AuthGlassMessage extends StatelessWidget {
  const AuthGlassMessage({super.key, required this.text, this.error = true});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error ? TechColors.statusRed : TechColors.statusGreen;

    return GlassContainer(
      shape: const LiquidRoundedSuperellipse(borderRadius: 12),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      child: Row(
        children: [
          Icon(
            error
                ? CupertinoIcons.exclamationmark_circle
                : CupertinoIcons.checkmark_circle,
            color: color,
            size: 15,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 11, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
