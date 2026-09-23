import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../tech_background.dart';
import '../../core/auth/insightflow_auth_service.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _loading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmController.text;

    if (name.isEmpty || email.isEmpty || password.isEmpty || confirm.isEmpty) {
      setState(() => _error = 'Complete all fields to create your account.');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    if (password != confirm) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final credential =
          await InsightFlowAuthService.createUserWithEmailAndPassword(
        email,
        password,
      );

      if (name.isNotEmpty) {
        await credential.user?.updateDisplayName(name);
      }
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
                                const Text(
                                  'Create account',
                                  style: TextStyle(
                                    color: TechColors.textPrimary,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  'Create secure access to your InsightFlow workspace.',
                                  style: TextStyle(
                                    color: TechColors.textMuted,
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                ..._formChildren(),
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

  List<Widget> _formChildren() {
    return [
      _SignUpField(
        controller: _nameController,
        label: 'Full name',
        icon: CupertinoIcons.person,
        enabled: !_loading,
        autofillHints: const [AutofillHints.name],
      ),
      const SizedBox(height: 14),
      _SignUpField(
        controller: _emailController,
        label: 'Email',
        icon: CupertinoIcons.mail,
        keyboardType: TextInputType.emailAddress,
        enabled: !_loading,
        autofillHints: const [AutofillHints.email],
      ),
      const SizedBox(height: 14),
      _SignUpField(
        controller: _passwordController,
        label: 'Password',
        icon: CupertinoIcons.lock,
        obscureText: _obscurePassword,
        enabled: !_loading,
        autofillHints: const [AutofillHints.newPassword],
        suffix: IconButton(
          onPressed: _loading
              ? null
              : () => setState(() => _obscurePassword = !_obscurePassword),
          icon: Icon(
            _obscurePassword ? CupertinoIcons.eye : CupertinoIcons.eye_slash,
            color: TechColors.textMuted,
            size: 18,
          ),
        ),
      ),
      const SizedBox(height: 14),
      _SignUpField(
        controller: _confirmController,
        label: 'Confirm password',
        icon: CupertinoIcons.lock_shield,
        obscureText: _obscureConfirm,
        enabled: !_loading,
        autofillHints: const [AutofillHints.newPassword],
        suffix: IconButton(
          onPressed: _loading
              ? null
              : () => setState(() => _obscureConfirm = !_obscureConfirm),
          icon: Icon(
            _obscureConfirm ? CupertinoIcons.eye : CupertinoIcons.eye_slash,
            color: TechColors.textMuted,
            size: 18,
          ),
        ),
        onSubmitted: (_) => _signUp(),
      ),
      if (_error != null) ...[
        const SizedBox(height: 14),
        _SignUpMessage(text: _error!),
      ],
      const SizedBox(height: 22),
      SizedBox(
        height: 52,
        child: FilledButton(
          onPressed: _loading ? null : _signUp,
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
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text(
                  'Create account',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
        ),
      ),
      const SizedBox(height: 18),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Already have an account? ',
            style: TextStyle(color: TechColors.textMuted, fontSize: 12),
          ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: _loading ? null : () => Navigator.of(context).pop(),
            child: const Text(
              'Sign in',
              style: TextStyle(color: TechColors.borderActive, fontSize: 12),
            ),
          ),
        ],
      ),
    ];
  }
}

class _SignUpField extends StatelessWidget {
  const _SignUpField({
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
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
    );
  }
}

class _SignUpMessage extends StatelessWidget {
  const _SignUpMessage({required this.text});

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
