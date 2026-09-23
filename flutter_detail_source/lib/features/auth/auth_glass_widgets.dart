import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../tech_background.dart';
import '../../core/interop/office_host.dart';

/// Shared Flutter-only shell for authentication.
///
/// This deliberately uses the same LiquidGlassScope, TechAnimatedBackground,
/// GlassCard, GlassContainer and TechColors used by DataScreen. Authentication
/// is rendered entirely with Flutter widgets.
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
            const Positioned.fill(
              child: GlassBackgroundSource(
                child: TechAnimatedBackground(),
              ),
            ),
            Positioned.fill(
              child: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                      child: GlassCard(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                        shape: const LiquidRoundedSuperellipse(
                          borderRadius: 16,
                        ),
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
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 440),
                            child: GlassContainer(
                              useOwnLayer: true,
                              quality: glassQuality,
                              settings: TechColors.sectionGlass,
                              shape: const LiquidRoundedSuperellipse(
                                borderRadius: 4,
                              ),
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      color: TechColors.textPrimary,
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    subtitle,
                                    style: const TextStyle(
                                      color: TechColors.textMuted,
                                      fontSize: 11,
                                      height: 1.35,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
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
        isRunningInsideOffice ? GlassQuality.minimal : GlassQuality.standard;

    return GlassContainer(
      useOwnLayer: true,
      quality: glassQuality,
      settings: TechColors.fieldGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 4),
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
            fontSize: 11,
            fontFamily: 'monospace',
          ),
          floatingLabelStyle: const TextStyle(
            color: TechColors.borderActive,
            fontSize: 10,
            fontFamily: 'monospace',
          ),
          prefixIcon: Icon(
            icon,
            color: TechColors.textMuted,
            size: 16,
          ),
          suffixIcon: suffix,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: TechColors.borderMuted, width: 0.6),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: TechColors.borderMuted, width: 0.6),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: TechColors.borderActive, width: 0.8),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: TechColors.borderMuted, width: 0.4),
          ),
          contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
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
    return SizedBox(
      height: 38,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: TechColors.borderActive.withValues(alpha: 0.14),
          foregroundColor: TechColors.textPrimary,
          disabledBackgroundColor: TechColors.borderMuted.withValues(alpha: 0.35),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(4)),
            side: BorderSide(
              color: TechColors.borderActive,
              width: 0.65,
            ),
          ),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        child: loading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: TechColors.borderActive,
                ),
              )
            : Text(
                label.toUpperCase(),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        border: Border.all(color: color.withValues(alpha: 0.28)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontFamily: 'monospace',
        ),
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
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: TechColors.borderActive,
          fontSize: 10,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
