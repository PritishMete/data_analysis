import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../tech_background.dart';
import '../../core/auth/insightflow_auth_service.dart';
import 'sign_up_screen.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await InsightFlowAuthService.signInWithEmailAndPassword(email, password);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = InsightFlowAuthService.userFacingAuthError(error);
      });
      return;
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Enter your email first to reset your password.');
      return;
    }

    try {
      await InsightFlowAuthService.sendPasswordResetEmail(email);
      if (!mounted) return;
      setState(() => _error = 'Password reset email sent. Check your inbox.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = InsightFlowAuthService.userFacingAuthError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return _AuthShell(
      title: 'Sign in',
      subtitle: 'Access your InsightFlow workspace securely.',
      children: [
        _GlassTextField(
          controller: _emailController,
          label: 'Email',
          icon: CupertinoIcons.mail,
          keyboardType: TextInputType.emailAddress,
          enabled: !_loading,
          autofillHints: const [AutofillHints.username],
          onSubmitted: (_) => _signIn(),
        ),
        const SizedBox(height: 14),
        _GlassTextField(
          controller: _passwordController,
          label: 'Password',
          icon: CupertinoIcons.lock,
          obscureText: _obscurePassword,
          enabled: !_loading,
          autofillHints: const [AutofillHints.password],
          suffix: IconButton(
            tooltip: _obscurePassword ? 'Show password' : 'Hide password',
            onPressed: _loading
                ? null
                : () => setState(() => _obscurePassword = !_obscurePassword),
            icon: Icon(
              _obscurePassword ? CupertinoIcons.eye : CupertinoIcons.eye_slash,
              color: TechColors.textMuted,
              size: 18,
            ),
          ),
          onSubmitted: (_) => _signIn(),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: _loading ? null : _resetPassword,
            child: const Text(
              'Forgot password?',
              style: TextStyle(color: TechColors.borderActive, fontSize: 12),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          _AuthMessage(text: _error!),
        ],
        const SizedBox(height: 20),
        _GlassPrimaryButton(
          label: 'Sign in',
          loading: _loading,
          onPressed: _loading ? null : _signIn,
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'New to InsightFlow? ',
              style: TextStyle(color: TechColors.textMuted, fontSize: 12),
            ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: _loading
                  ? null
                  : () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const SignUpScreen(),
                        ),
                      ),
              child: const Text(
                'Create account',
                style: TextStyle(color: TechColors.borderActive, fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _AuthShell extends StatelessWidget {
  const _AuthShell({
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
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                      child: GlassCard(
                        padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
                        shape: const LiquidRoundedSuperellipse(borderRadius: 16),
                        child: Row(
                          children: [
                            const Icon(Icons.terminal,
                                color: TechColors.borderActive, size: 18),
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
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: GlassContainer(
                            useOwnLayer: true,
                            quality: GlassQuality.minimal,
                            settings: TechColors.sectionGlass,
                            shape: const LiquidRoundedSuperellipse(borderRadius: 16),
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  title,
                                  style: const TextStyle(
                                    color: TechColors.textPrimary,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  subtitle,
                                  style: const TextStyle(
                                    color: TechColors.textMuted,
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                ...children,
                              ],
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

class _GlassTextField extends StatelessWidget {
  const _GlassTextField({
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
    return Container(
      decoration: BoxDecoration(
        color: TechColors.fieldGlass.glassColor ?? Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscureText,
        enabled: enabled,
        autofillHints: autofillHints,
        onSubmitted: onSubmitted,
        style: const TextStyle(color: TechColors.textPrimary, fontSize: 14),
        cursorColor: TechColors.borderActive,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: TechColors.textMuted),
          prefixIcon: Icon(icon, color: TechColors.textMuted, size: 18),
          suffixIcon: suffix,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
    );
  }
}

class _GlassPrimaryButton extends StatelessWidget {
  const _GlassPrimaryButton({
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
      height: 52,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: TechColors.borderActive.withValues(alpha: 0.16),
          foregroundColor: TechColors.textPrimary,
          disabledBackgroundColor: Colors.white.withValues(alpha: 0.06),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: TechColors.borderActive.withValues(alpha: 0.42),
            ),
          ),
        ),
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
      ),
    );
  }
}

class _AuthMessage extends StatelessWidget {
  const _AuthMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: TechColors.statusRed.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: TechColors.statusRed.withValues(alpha: 0.28),
        ),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: TechColors.textPrimary, fontSize: 12),
      ),
    );
  }
}
