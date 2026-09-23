import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../tech_background.dart';
import '../../core/interop/office_host.dart';

/// Shared Flutter-only liquid-glass shell for authentication.
///
/// The authentication surface intentionally follows the same composition as
/// the main InsightFlow workspace: TechAnimatedBackground -> LiquidGlassScope
/// -> glass app bar -> elevated glass content surface.
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
    final glassQuality = kIsWeb || isRunningInsideOffice
        ? GlassQuality.minimal
        : GlassQuality.standard;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      body: LiquidGlassScope(
        child: Stack(
          children: [
            Positioned.fill(
              child: GlassBackgroundSource(
                child: const TechAnimatedBackground(),
              ),
            ),
            Positioned.fill(
              child: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                      child: GlassCard(
                        padding: const EdgeInsets.fromLTRB(18, 12, 14, 12),
                        shape: const LiquidRoundedSuperellipse(borderRadius: 18),
                        child: Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: TechColors.borderActive.withValues(alpha: 0.10),
                                border: Border.all(
                                  color: TechColors.borderActive.withValues(alpha: 0.35),
                                ),
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: const Icon(
                                Icons.auto_awesome,
                                color: TechColors.borderActive,
                                size: 17,
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'InsightFlow',
                                  style: TextStyle(
                                    color: TechColors.textPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'monospace',
                                    letterSpacing: 0.3,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'AI DATA WORKSPACE',
                                  style: TextStyle(
                                    color: TechColors.textMuted,
                                    fontSize: 8,
                                    fontWeight: FontWeight.w600,
                                    fontFamily: 'monospace',
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ],
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: TechColors.statusGreen.withValues(alpha: 0.06),
                                border: Border.all(
                                  color: TechColors.statusGreen.withValues(alpha: 0.22),
                                ),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.lock_outline,
                                    size: 11,
                                    color: TechColors.statusGreen,
                                  ),
                                  SizedBox(width: 5),
                                  Text(
                                    'SECURE SESSION',
                                    style: TextStyle(
                                      color: TechColors.statusGreen,
                                      fontSize: 8,
                                      fontWeight: FontWeight.w700,
                                      fontFamily: 'monospace',
                                      letterSpacing: 0.7,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 620),
                            child: GlassContainer(
                              useOwnLayer: true,
                              quality: glassQuality,
                              settings: TechColors.panelGlass,
                              shape: const LiquidRoundedSuperellipse(borderRadius: 24),
                              padding: const EdgeInsets.fromLTRB(30, 28, 30, 26),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 46,
                                        height: 46,
                                        decoration: BoxDecoration(
                                          color: TechColors.borderActive.withValues(alpha: 0.10),
                                          border: Border.all(
                                            color: TechColors.borderActive.withValues(alpha: 0.28),
                                          ),
                                          borderRadius: BorderRadius.circular(15),
                                          boxShadow: [
                                            BoxShadow(
                                              color: TechColors.borderActive.withValues(alpha: 0.08),
                                              blurRadius: 18,
                                              spreadRadius: 1,
                                            ),
                                          ],
                                        ),
                                        child: const Icon(
                                          Icons.fingerprint_rounded,
                                          color: TechColors.borderActive,
                                          size: 23,
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              title,
                                              style: const TextStyle(
                                                color: TechColors.textPrimary,
                                                fontSize: 20,
                                                fontWeight: FontWeight.w700,
                                                fontFamily: 'SFPro',
                                                letterSpacing: -0.2,
                                              ),
                                            ),
                                            const SizedBox(height: 5),
                                            Text(
                                              subtitle,
                                              style: const TextStyle(
                                                color: TechColors.textMuted,
                                                fontSize: 10,
                                                height: 1.5,
                                                fontFamily: 'monospace',
                                                letterSpacing: 0.45,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 24),
                                  Container(
                                    height: 1,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          TechColors.borderActive.withValues(alpha: 0.0),
                                          TechColors.borderActive.withValues(alpha: 0.28),
                                          TechColors.borderActive.withValues(alpha: 0.0),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 22),
                                  ...children,
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AuthGlassField extends StatelessWidget {
  const AuthGlassField({
    super.key,
    required this.controller,
    required this.label,
    required this.icon,
    this.keyboardType,
    this.obscureText = false,
    this.enabled = true,
    this.autofillHints,
    this.suffix,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType? keyboardType;
  final bool obscureText;
  final bool enabled;
  final Iterable<String>? autofillHints;
  final Widget? suffix;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final glassQuality =
        kIsWeb || isRunningInsideOffice ? GlassQuality.minimal : GlassQuality.standard;

    return GlassContainer(
      useOwnLayer: true,
      quality: glassQuality,
      settings: TechColors.fieldGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 14),
      padding: EdgeInsets.zero,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscureText,
        enabled: enabled,
        autofillHints: autofillHints,
        onSubmitted: onSubmitted,
        style: const TextStyle(
          color: TechColors.textPrimary,
          fontSize: 12,
          fontFamily: 'monospace',
        ),
        cursorColor: TechColors.borderActive,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(
            color: TechColors.textMuted,
            fontSize: 10,
            fontFamily: 'monospace',
            letterSpacing: 0.5,
          ),
          floatingLabelStyle: const TextStyle(
            color: TechColors.borderActive,
            fontSize: 10,
            fontFamily: 'monospace',
            letterSpacing: 0.4,
          ),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Icon(icon, color: TechColors.textMuted, size: 17),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 44),
          suffixIcon: suffix,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
              color: TechColors.borderMuted.withValues(alpha: 0.75),
              width: 0.7,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
              color: TechColors.borderMuted.withValues(alpha: 0.85),
              width: 0.7,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(
              color: TechColors.borderActive,
              width: 1.0,
            ),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
              color: TechColors.borderMuted.withValues(alpha: 0.45),
              width: 0.6,
            ),
          ),
          contentPadding: const EdgeInsets.fromLTRB(14, 15, 12, 15),
        ),
      ),
    );
  }
}

class AuthGlassPrimaryButton extends StatelessWidget {
  const AuthGlassPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;

    return SizedBox(
      height: 48,
      child: GlassButton.custom(
        onTap: enabled ? onPressed : null,
        enabled: enabled,
        style: GlassButtonStyle.prominent,
        shape: const LiquidRoundedSuperellipse(borderRadius: 14),
        settings: TechColors.sectionGlass,
        quality: kIsWeb || isRunningInsideOffice
            ? GlassQuality.minimal
            : GlassQuality.standard,
        useOwnLayer: true,
        label: label,
        child: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: TechColors.borderActive,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label.toUpperCase(),
                    style: const TextStyle(
                      color: TechColors.textPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                      letterSpacing: 0.9,
                    ),
                  ),
                  const SizedBox(width: 9),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    color: TechColors.borderActive,
                    size: 16,
                  ),
                ],
              ),
      ),
    );
  }
}

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
      quality: kIsWeb || isRunningInsideOffice
          ? GlassQuality.minimal
          : GlassQuality.standard,
      settings: TechColors.fieldGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 12),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      child: Row(
        children: [
          Icon(
            error ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
            color: color,
            size: 17,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 10,
                height: 1.45,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AuthGlassLink extends StatelessWidget {
  const AuthGlassLink({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: TechColors.borderActive,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: TechColors.borderActive,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          fontFamily: 'monospace',
          letterSpacing: 0.45,
        ),
      ),
    );
  }
}
