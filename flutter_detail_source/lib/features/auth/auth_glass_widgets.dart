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
              child: GlassBackgroundSource(child: TechAnimatedBackground()),
            ),
            Positioned.fill(
              child: SafeArea(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 32),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          GlassContainer(
                            useOwnLayer: true,
                            quality: _authGlassQuality,
                            settings: TechColors.sectionGlass,
                            shape: const LiquidRoundedSuperellipse(borderRadius: 18),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            child: Row(
                              children: [
                                GlassContainer(
                                  useOwnLayer: true,
                                  quality: _authGlassQuality,
                                  settings: TechColors.fieldGlass,
                                  shape: const LiquidRoundedSuperellipse(borderRadius: 12),
                                  padding: const EdgeInsets.all(9),
                                  child: const Icon(
                                    Icons.auto_awesome_rounded,
                                    color: TechColors.borderActive,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const Expanded(
                                  child: Text(
                                    'INSIGHTFLOW',
                                    style: TextStyle(
                                      color: TechColors.textPrimary,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.4,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: TechColors.statusGreen.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: TechColors.statusGreen.withValues(alpha: 0.30),
                                    ),
                                  ),
                                  child: const Text(
                                    'SECURE',
                                    style: TextStyle(
                                      color: TechColors.statusGreen,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1,
                                      fontFamily: 'monospace',
                                    ),
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
                            padding: const EdgeInsets.all(22),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _AuthHeader(title: title, subtitle: subtitle),
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
            ),
          ],
        ),
      ),
    );
  }
}

class _AuthHeader extends StatelessWidget {
  const _AuthHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            GlassContainer(
              useOwnLayer: true,
              quality: _authGlassQuality,
              settings: TechColors.fieldGlass,
              shape: const LiquidRoundedSuperellipse(borderRadius: 12),
              padding: const EdgeInsets.all(9),
              child: const Icon(
                Icons.person_outline_rounded,
                color: TechColors.borderActive,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title.toUpperCase(),
                style: const TextStyle(
                  color: TechColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .8,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          subtitle,
          style: const TextStyle(
            color: TechColors.textMuted,
            fontSize: 11,
            height: 1.4,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 14),
        Container(
          height: 1,
          decoration: BoxDecoration(
            color: TechColors.borderActive.withValues(alpha: .18),
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ],
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
          fontSize: 13,
          fontFamily: 'monospace',
        ),
        cursorColor: TechColors.borderActive,
        decoration: InputDecoration(
          hintText: 'Enter ${label.toLowerCase()}',
          hintStyle: const TextStyle(
            color: TechColors.textMuted,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
          prefixIcon: Icon(icon, size: 17, color: TechColors.textMuted),
          suffixIcon: suffix,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: TechColors.borderMuted.withValues(alpha: .70),
              width: .8,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: TechColors.borderMuted.withValues(alpha: .70),
              width: .8,
            ),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: TechColors.borderActive, width: 1),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: TechColors.borderMuted.withValues(alpha: .35),
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
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
      height: 46,
      width: double.infinity,
      child: GlassButton.custom(
        onTap: enabled ? onPressed! : () {},
        enabled: enabled,
        style: GlassButtonStyle.prominent,
        settings: TechColors.sectionGlass,
        useOwnLayer: true,
        quality: _authGlassQuality,
        shape: const LiquidRoundedSuperellipse(borderRadius: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: TechColors.borderActive,
                ),
              )
            else
              const Icon(
                Icons.arrow_forward_rounded,
                size: 17,
                color: TechColors.borderActive,
              ),
            const SizedBox(width: 8),
            Text(
              loading ? 'PLEASE WAIT...' : label.toUpperCase(),
              style: const TextStyle(
                color: TechColors.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: .8,
                fontFamily: 'monospace',
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
    return GlassContainer(
      useOwnLayer: true,
      quality: _authGlassQuality,
      settings: TechColors.fieldGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(
            error ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
            color: color,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 10,
                height: 1.35,
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
          letterSpacing: .5,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
