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
  const AuthGlassScaffold({super.key, required this.title, required this.subtitle, required this.children});
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
            const Positioned.fill(child: GlassBackgroundSource(child: TechAnimatedBackground())),
            SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  GlassCard(
                    padding: const EdgeInsets.all(16),
                    shape: const LiquidRoundedSuperellipse(borderRadius: 18),
                    child: Row(
                      children: [
                        Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: CupertinoColors.white.withValues(alpha: 0.08),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(CupertinoIcons.lock_shield_fill, size: 16, color: CupertinoColors.activeBlue),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: TextStyle(color: CupertinoColors.label.resolveFrom(context), fontSize: 15, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 3),
                              Text(subtitle, style: TextStyle(color: CupertinoColors.secondaryLabel.resolveFrom(context), fontSize: 11)),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: CupertinoColors.activeGreen.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: CupertinoColors.activeGreen.withValues(alpha: 0.5)),
                          ),
                          child: const Text('SECURE', style: TextStyle(color: CupertinoColors.activeGreen, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  GlassCard(
                    padding: const EdgeInsets.all(16),
                    shape: const LiquidRoundedSuperellipse(borderRadius: 18),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AuthGlassField extends StatelessWidget {
  const AuthGlassField({super.key, required this.controller, required this.label, required this.icon, this.keyboardType, this.obscureText = false, this.enabled = true, this.autofillHints, this.suffix, this.onSubmitted});
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
        Text(label, style: TextStyle(color: CupertinoColors.secondaryLabel.resolveFrom(context), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.4)),
        const SizedBox(height: 8),
        GlassContainer(
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
            style: TextStyle(color: CupertinoColors.label.resolveFrom(context), fontSize: 13),
            cursorColor: CupertinoColors.activeBlue,
            decoration: InputDecoration(
              hintText: 'Enter ${label.toLowerCase()}',
              hintStyle: TextStyle(color: CupertinoColors.secondaryLabel.resolveFrom(context), fontSize: 13),
              prefixIcon: Icon(icon, color: CupertinoColors.secondaryLabel.resolveFrom(context), size: 17),
              suffixIcon: suffix,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: CupertinoColors.activeBlue, width: 1)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              isDense: true,
            ),
          ),
        ),
      ],
    );
  }
}

class AuthGlassPrimaryButton extends StatelessWidget {
  const AuthGlassPrimaryButton({super.key, required this.label, required this.onPressed, this.loading = false});
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return GlassButton(
      onTap: onPressed,
      enabled: onPressed != null && !loading,
      width: double.infinity,
      height: 48,
      style: GlassButtonStyle.prominent,
      shape: const LiquidRoundedSuperellipse(borderRadius: 16),
      icon: loading ? const CupertinoActivityIndicator(color: CupertinoColors.white) : const Icon(CupertinoIcons.arrow_right, size: 16),
      label: loading ? 'Working…' : label,
    );
  }
}

class AuthGlassMessage extends StatelessWidget {
  const AuthGlassMessage({super.key, required this.text, this.error = true});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error ? CupertinoColors.systemRed : CupertinoColors.activeGreen;
    return GlassContainer(
      settings: TechColors.fieldGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(error ? CupertinoIcons.exclamationmark_circle : CupertinoIcons.checkmark_circle, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 11, height: 1.4))),
        ],
      ),
    );
  }
}

class AuthGlassLink extends StatelessWidget {
  const AuthGlassLink({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      minimumSize: Size.zero,
      onPressed: onPressed,
      child: Text(label, style: TextStyle(color: CupertinoColors.activeBlue, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}
