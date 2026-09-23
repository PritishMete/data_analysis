import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../tech_background.dart';
import '../../core/interop/office_host.dart';

GlassQuality get _authGlassQuality =>
    kIsWeb || isRunningInsideOffice ? GlassQuality.minimal : GlassQuality.standard;

/// Authentication shell styled from the same glass system used by DataScreen.
/// Auth remains functionally separate, but visually belongs to the tool.
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
    return Scaffold(
      backgroundColor: TechColors.bgBlack,
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
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                      child: GlassContainer(
                        useOwnLayer: true,
                        quality: _authGlassQuality,
                        settings: TechColors.panelGlass,
                        shape: const LiquidRoundedSuperellipse(borderRadius: 18),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 14,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.terminal_rounded,
                              color: TechColors.borderActive,
                              size: 17,
                            ),
                            const SizedBox(width: 9),
                            Text(
                              'InsightFlow',
                              style: TextStyle(
                                color: CupertinoColors.label.resolveFrom(context),
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const Spacer(),
                            Icon(
                              Icons.lock_outline_rounded,
                              size: 16,
                              color: CupertinoColors.secondaryLabel
                                  .resolveFrom(context),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(8, 20, 8, 24),
                        child: GlassContainer(
                          useOwnLayer: true,
                          quality: _authGlassQuality,
                          settings: TechColors.panelGlass,
                          shape:
                              const LiquidRoundedSuperellipse(borderRadius: 20),
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: TechColors.borderActive
                                          .withValues(alpha: .10),
                                      border: Border.all(
                                        color: TechColors.borderActive
                                            .withValues(alpha: .16),
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.person_outline_rounded,
                                      size: 18,
                                      color: TechColors.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          title,
                                          style: const TextStyle(
                                            color: TechColors.textPrimary,
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700,
                                            height: 1.15,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          subtitle,
                                          style: const TextStyle(
                                            color: TechColors.textMuted,
                                            fontSize: 11,
                                            height: 1.3,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              ...children,
                            ],
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
    return GlassContainer(
      useOwnLayer: true,
      quality: _authGlassQuality,
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
          fontWeight: FontWeight.w500,
        ),
        cursorColor: TechColors.borderActive,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(
            color: TechColors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
          floatingLabelStyle: const TextStyle(
            color: TechColors.borderActive,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
          prefixIcon: Icon(icon, color: TechColors.textMuted, size: 17),
          suffixIcon: suffix,
          filled: true,
          fillColor: Colors.white.withValues(alpha: .025),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
              color: Colors.white.withValues(alpha: .12),
              width: .8,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
              color: Colors.white.withValues(alpha: .12),
              width: .8,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(
              color: TechColors.borderActive,
              width: 1,
            ),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
              color: TechColors.borderMuted.withValues(alpha: .55),
            ),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
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
      height: 50,
      child: GlassButton.custom(
        onTap: enabled ? onPressed : null,
        enabled: enabled,
        style: GlassButtonStyle.prominent,
        shape: const LiquidRoundedSuperellipse(borderRadius: 16),
        settings: TechColors.sectionGlass,
        quality: _authGlassQuality,
        useOwnLayer: true,
        label: label,
        child: loading
            ? const SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(
                  strokeWidth: 1.7,
                  color: TechColors.borderActive,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.bolt_rounded,
                    color: TechColors.textPrimary,
                    size: 18,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: const TextStyle(
                      color: TechColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .22)),
      ),
      child: Row(
        children: [
          Icon(
            error
                ? Icons.error_outline_rounded
                : Icons.check_circle_outline_rounded,
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
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: TechColors.borderActive,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
