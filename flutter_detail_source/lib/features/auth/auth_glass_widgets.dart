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
      appBar: GlassAppBar(
        centerTitle: false,
        title: Row(
          children: [
            const Icon(
              Icons.terminal,
              color: TechColors.borderActive,
              size: 17,
            ),
            const SizedBox(width: 9),
            const Text(
              'InsightFlow',
              style: TextStyle(
                color: TechColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
      edgeFade: false,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final horizontalPadding = constraints.maxWidth < 420 ? 8.0 : 16.0;

          return SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              12,
              horizontalPadding,
              28,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
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
              ),
            ),
          );
        },
      ),
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
