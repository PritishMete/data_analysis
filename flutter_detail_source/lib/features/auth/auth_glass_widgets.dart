import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../../tech_background.dart';

import '../../app_colors.dart';

/// Authentication shell adapted directly from the LiquidGlassUi auth pattern.
///
/// The renderer/theme/utility stack is the existing InsightFlow Liquid Glass
/// implementation. This file only composes those shared primitives into the
/// authentication surface; it does not introduce a second renderer or theme.
class AuthGlassScaffold extends StatelessWidget {
  const AuthGlassScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    this.wideContent = false,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final bool wideContent;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LiquidGlassScope(
        child: Stack(
          children: [
            const Positioned.fill(
              child: GlassBackgroundSource(
                child: TechAnimatedBackground(),
              ),
            ),
            Positioned.fill(
              child: SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 420;
                    final short = constraints.maxHeight < 620;
                    final horizontal = narrow ? 16.0 : 24.0;
                    final vertical = short ? 16.0 : 32.0;

                    final card = ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: wideContent ? 1280 : 420,
                      ),
                      child: GlassCard(
                        useOwnLayer: true,
                        settings: kAuthPanelGlass,
                        quality: GlassQuality.standard,
                        shape: kAuthPanelShape,
                        padding: EdgeInsets.all(narrow ? 20 : 28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: kAuthAccent.withValues(alpha: 0.10),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: kAuthAccent.withValues(alpha: 0.35),
                                    ),
                                  ),
                                  child: const Icon(
                                    CupertinoIcons.lock_shield_fill,
                                    color: kAuthAccent,
                                    size: 19,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 22,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.1,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        subtitle,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.white.withValues(
                                            alpha: 0.58,
                                          ),
                                          fontSize: 11,
                                          height: 1.35,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                            ...children,
                          ],
                        ),
                      ),
                    );

                    return SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontal,
                        vertical: vertical,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight - vertical * 2,
                        ),
                        child: Center(child: card),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// LiquidGlassUi auth preset values.
const kAuthPanelGlass = TechColors.panelGlass;

const kAuthFieldGlass = TechColors.fieldGlass;

const kAuthPanelShape =
    LiquidRoundedSuperellipse(borderRadius: 28);

const kAuthFieldShape =
    LiquidRoundedSuperellipse(borderRadius: 10);

const kAuthAccent = Color(0xFF3DDC97);

/// Compact input hierarchy matching the LiquidGlassUi auth composition.
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
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Status feedback uses the same glass container system as the rest of the app.
class AuthGlassMessage extends StatelessWidget {
  const AuthGlassMessage({
    super.key,
    required this.text,
    this.error = true,
  });

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error ? TechColors.statusRed : TechColors.statusGreen;

    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: LiquidGlassSettings(
        thickness: 12,
        blur: 6,
        glassColor: error
            ? const Color(0x59B71C1C)
            : const Color(0x591FA971),
        refractiveIndex: 1.1,
      ),
      shape: const LiquidRoundedSuperellipse(borderRadius: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
              style: TextStyle(
                color: color,
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Animated dark liquid background from the LiquidGlassUi auth experience.
