import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../tech_background.dart';
import '../../core/interop/office_host.dart';

GlassQuality get _authGlassQuality =>
    kIsWeb || isRunningInsideOffice ? GlassQuality.minimal : GlassQuality.standard;

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
      backgroundColor: Colors.transparent,
      body: LiquidGlassScope(
        child: Stack(
          children: [
            const Positioned.fill(
              child: GlassBackgroundSource(
                child: TechAnimatedBackground(),
              ),
            ),
            SafeArea(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      children: [
                        GlassContainer(
                          useOwnLayer: true,
                          quality: _authGlassQuality,
                          settings: TechColors.sectionGlass,
                          shape: const LiquidRoundedSuperellipse(borderRadius: 18),
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: TechColors.borderActive.withValues(alpha: 0.08),
                                  border: Border.all(
                                    color: TechColors.borderActive.withValues(alpha: 0.22),
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.auto_awesome,
                                  color: TechColors.borderActive,
                                  size: 17,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      title.toUpperCase(),
                                      style: const TextStyle(
                                        color: TechColors.textPrimary,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        fontFamily: 'monospace',
                                        letterSpacing: 0.6,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      subtitle,
                                      style: const TextStyle(
                                        color: TechColors.textMuted,
                                        fontSize: 9,
                                        fontFamily: 'monospace',
                                        letterSpacing: 0.35,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: TechColors.statusGreen.withValues(alpha: 0.07),
                                  border: Border.all(
                                    color: TechColors.statusGreen.withValues(alpha: 0.25),
                                  ),
                                  borderRadius: BorderRadius.circular(8),
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
                        const SizedBox(height: 12),
                        GlassContainer(
                          useOwnLayer: true,
                          quality: _authGlassQuality,
                          settings: TechColors.panelGlass,
                          shape: const LiquidRoundedSuperellipse(borderRadius: 22),
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.lock_person_outlined,
                                    color: TechColors.borderActive,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 9),
                                  Expanded(
                                    child: Text(
                                      title.toUpperCase(),
                                      style: const TextStyle(
                                        color: TechColors.textPrimary,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        fontFamily: 'monospace',
                                        letterSpacing: 0.6,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 13),
                              Container(
                                height: 1,
                                color: TechColors.borderActive.withValues(alpha: 0.18),
                              ),
                              const SizedBox(height: 18),
                              ...children,
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: TechColors.textMuted,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
            letterSpacing: 0.75,
          ),
        ),
        const SizedBox(height: 6),
        GlassContainer(
          useOwnLayer: true,
          quality: _authGlassQuality,
          settings: TechColors.fieldGlass,
          shape: const LiquidRoundedSuperellipse(borderRadius: 12),
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
              hintText: 'Enter ${label.toLowerCase()}',
              hintStyle: const TextStyle(
                color: TechColors.textMuted,
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
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: TechColors.borderMuted.withValues(alpha: 0.55),
                  width: 0.7,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: TechColors.borderMuted.withValues(alpha: 0.55),
                  width: 0.7,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: TechColors.borderActive.withValues(alpha: 0.8),
                  width: 1,
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 13,
              ),
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
      height: 46,
      child: GlassButton.custom(
        onTap: enabled ? onPressed : null,
        enabled: enabled,
        style: GlassButtonStyle.prominent,
        shape: const LiquidRoundedSuperellipse(borderRadius: 12),
        settings: TechColors.sectionGlass,
        quality: _authGlassQuality,
        useOwnLayer: true,
        label: label,
        child: loading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
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
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                      letterSpacing: 0.75,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    color: TechColors.borderActive,
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
      quality: _authGlassQuality,
      settings: TechColors.fieldGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 12),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
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
                fontSize: 9,
                height: 1.4,
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
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: TechColors.borderActive,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          fontFamily: 'monospace',
          letterSpacing: 0.45,
        ),
      ),
    );
  }
}
