import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../tech_background.dart';
import '../../core/interop/office_host.dart';

/// Shared Flutter-only authentication surface.
///
/// This intentionally reuses the same visual primitives as DataScreen:
/// TechAnimatedBackground, LiquidGlassScope, GlassCard, GlassContainer and
/// the TechColors glass presets. Authentication is part of the workspace shell,
/// not a separate HTML-style form.
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
                    // Keep the authentication header visually identical to
                    // the main DataScreen glass app bar.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                      child: GlassCard(
                        padding: const EdgeInsets.all(16),
                        shape: const LiquidRoundedSuperellipse(borderRadius: 18),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.terminal,
                              color: CupertinoColors.activeBlue,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              'InsightFlow',
                              style: TextStyle(
                                color: CupertinoColors.label.resolveFrom(context),
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Container(
                              width: 1,
                              height: 16,
                              color: TechColors.borderMuted,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'AUTH',
                              style: const TextStyle(
                                color: CupertinoColors.secondaryLabel.resolveFrom(context),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.4,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: CupertinoColors.activeGreen.withValues(alpha: 0.15),
                                border: Border.all(
                                  color: CupertinoColors.activeGreen.withValues(alpha: 0.5),
                                ),
                                borderRadius: BorderRadius.circular(14),
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
                                    'SECURE',
                                    style: TextStyle(
                                      color: CupertinoColors.activeGreen,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.6,
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
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 520),
                            child: GlassContainer(
                              useOwnLayer: true,
                              quality: glassQuality,
                              settings: TechColors.panelGlass,
                              shape: const LiquidRoundedSuperellipse(borderRadius: 18),
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.lock_person_outlined,
                                        color: CupertinoColors.activeBlue,
                                        size: 17,
                                      ),
                                      const SizedBox(width: 9),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              title,
                                              style: const TextStyle(
                                                color: CupertinoColors.label.resolveFrom(context),
                                                fontSize: 15,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              subtitle,
                                              style: const TextStyle(
                                                color: TechColors.textMuted,
                                                fontSize: 9,
                                                height: 1.35,
                                                fontFamily: 'monospace',
                                                letterSpacing: 0.35,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Container(
                                    height: 1,
                                    color: TechColors.borderMuted.withValues(alpha: 0.8),
                                  ),
                                  const SizedBox(height: 14),
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
    final glassQuality = kIsWeb || isRunningInsideOffice
        ? GlassQuality.minimal
        : GlassQuality.standard;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 5),
        GlassContainer(
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
              fontSize: 13,
            ),
            cursorColor: TechColors.borderActive,
            decoration: InputDecoration(
              hintText: 'Enter ${label.toLowerCase()}',
              hintStyle: const TextStyle(
                color: TechColors.textMuted,
                fontSize: 11,
              ),
              prefixIcon: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(
                  icon,
                  color: TechColors.textMuted,
                  size: 15,
                ),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 38),
              suffixIcon: suffix,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: CupertinoColors.separator.withValues(alpha: 0.5),
                  width: 0.8,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: CupertinoColors.separator.withValues(alpha: 0.5),
                  width: 0.8,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(
                  color: CupertinoColors.activeBlue,
                  width: 1,
                ),
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: TechColors.borderMuted.withValues(alpha: 0.45),
                  width: 0.6,
                ),
              ),
              contentPadding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              isDense: true,
            ),
          ),
        ),
      ],
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
        shape: const LiquidRoundedSuperellipse(borderRadius: 16),
        settings: TechColors.sectionGlass,
        quality: kIsWeb || isRunningInsideOffice
            ? GlassQuality.minimal
            : GlassQuality.standard,
        useOwnLayer: true,
        label: label,
        child: loading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
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
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    color: CupertinoColors.activeBlue,
                    size: 14,
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
      shape: const LiquidRoundedSuperellipse(borderRadius: 16),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          Icon(
            error ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
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
                height: 1.4,
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
        foregroundColor: CupertinoColors.activeBlue,
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: CupertinoColors.activeBlue,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          fontFamily: 'monospace',
          letterSpacing: 0.45,
        ),
      ),
    );
  }
}
