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
    this.brandedLayout = false,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final bool wideContent;
  final bool brandedLayout;

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
                        maxWidth: wideContent ? 1280 : 460,
                      ),
                      child: InsightFlowDialogSurface(
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

                    if (brandedLayout && constraints.maxWidth >= 900) {
                      return SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        padding: EdgeInsets.fromLTRB(48, vertical, 48, vertical),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight - vertical * 2,
                          ),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1240),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  const Expanded(child: _AuthBrandPanel()),
                                  const SizedBox(width: 64),
                                  SizedBox(width: 460, child: card),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }

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


/// Brand panel shown beside the authentication form on desktop-sized screens.
class _AuthBrandPanel extends StatelessWidget {
  const _AuthBrandPanel();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 540),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: kAuthAccent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: kAuthAccent.withValues(alpha: 0.42)),
                ),
                child: const Icon(
                  CupertinoIcons.chart_bar_square_fill,
                  color: kAuthAccent,
                  size: 27,
                ),
              ),
              const SizedBox(width: 14),
              const Text(
                'InsightFlow',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.7,
                ),
              ),
            ],
          ),
          const SizedBox(height: 52),
          const Text(
            'Turn your data into',
            style: TextStyle(
              color: Colors.white,
              fontSize: 35,
              height: 1.15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'actionable insights.',
            style: TextStyle(
              color: kAuthAccent,
              fontSize: 35,
              height: 1.15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'A secure, role-based analytics workspace built for teams that make decisions with data.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),
              fontSize: 15,
              height: 1.7,
            ),
          ),
          const SizedBox(height: 32),
          const _AuthFeatureRow(
            icon: CupertinoIcons.chart_bar_alt_fill,
            title: 'Powerful analytics',
            subtitle: 'Explore trends and performance in one place',
          ),
          const SizedBox(height: 18),
          const _AuthFeatureRow(
            icon: CupertinoIcons.lock_shield_fill,
            title: 'Role-based access',
            subtitle: 'Workspace access follows your assigned role',
          ),
          const SizedBox(height: 18),
          const _AuthFeatureRow(
            icon: CupertinoIcons.checkmark_shield_fill,
            title: 'Your data, protected',
            subtitle: 'Secure sign-in with verified email access',
          ),
          const SizedBox(height: 34),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: TechColors.panelBg.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: kAuthAccent.withValues(alpha: 0.22)),
            ),
            child: Row(
              children: [
                const Icon(CupertinoIcons.waveform_path, color: kAuthAccent, size: 25),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'One workspace. Clear permissions. Better decisions.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.82),
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthFeatureRow extends StatelessWidget {
  const _AuthFeatureRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: kAuthAccent.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kAuthAccent.withValues(alpha: 0.2)),
          ),
          child: Icon(icon, color: kAuthAccent, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(subtitle, style: TextStyle(color: Colors.white.withValues(alpha: 0.58), fontSize: 11, height: 1.4)),
            ],
          ),
        ),
      ],
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
